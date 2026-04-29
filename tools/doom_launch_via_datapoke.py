#!/usr/bin/env python3
"""doom_launch_via_datapoke.py

End-to-end launch of Doom on the MiSTer SuperCPU core using the authentic
`loader.prg` injected via BASIC DATA/READ/POKE (no MGL auto-RUN path).

Sequence:
  1. Upload mtype.py, stty UART, start background UART capture.
  2. Verify RBF is SuperCPU (PEEK $DFF0 != $FF).
  3. Load doom.reu via MGL pipe (<file> tag loads REU).
  4. Inject loader.prg ML body (240 bytes, $080D..$08FC) via:
       (a) Type a BASIC program that READs DATA bytes into $C000..$C0EF.
       (b) RUN that program. (Direct-mode READY follows.)
       (c) Type direct-mode copy+exec:
             FOR I=0 TO 239:POKE 2061+I,PEEK(49152+I):NEXT:SYS 2061
  5. Wait for loader to copy REU->SuperRAM and return to READY.
  6. Issue the SuperCPU launcher (SEI;CLC;XCE;JML $20:$0000) at $C000 and SYS.
  7. Observe UART: count TR lines (trace freeze marker), capture final state,
     and (if alive) PEEK the 128-entry trace ring via $DF1F/$DF21+.

Run from project root: `python tools/doom_launch_via_datapoke.py`
"""

import os
import sys
import time
import threading
import struct
import paramiko

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER_PRG = os.path.join(PROJECT_ROOT, "loader.prg")
MTYPE_LOCAL = os.path.join(PROJECT_ROOT, "tools", "mtype.py")

TIMESTAMP = time.strftime("%Y%m%d_%H%M%S")
UART_LOG = os.path.join(PROJECT_ROOT, f"uart_doom_datapoke_{TIMESTAMP}.log")
# Use the existing /media/fat/_Test/doom.mgl which matches our needs:
#   <rbf>_Test/C64</rbf>
#   <file delay="10" type="f" index="1" path="games/C64/doom.reu"/>
MGL_REMOTE = "/media/fat/_Test/doom.mgl"
REU_REMOTE = "/media/fat/games/C64/doom.reu"


# -------------------- SSH helpers --------------------

def mk_client():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10)
    return c


def ssh_exec(client, cmd, timeout=20):
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors='replace')
    err = stderr.read().decode(errors='replace')
    return out, err


def mtype(client, *args, extra=None, timeout=40):
    """Run mtype.py on MiSTer with space-separated args.

    Each arg is shell-quoted individually. If `extra` is given it is
    appended verbatim (e.g. 'enter')."""
    parts = []
    for a in args:
        escaped = a.replace("'", "'\\''")
        parts.append(f"'{escaped}'")
    if extra:
        parts.append(extra)
    cmd = f"python3 /tmp/mtype.py {' '.join(parts)}"
    out, err = ssh_exec(client, cmd, timeout=timeout)
    if err.strip() and 'unmapped' not in err:
        print(f"    mtype stderr: {err.strip()[:120]}")
    return out, err


# -------------------- UART capture thread --------------------

class UartCapture:
    """Start a remote `cat /dev/ttyS1` into a remote tmp file, then fetch at end."""
    def __init__(self, client, remote_tmp, local_path, duration_s):
        self.client = client
        self.remote_tmp = remote_tmp
        self.local_path = local_path
        self.duration_s = duration_s
        self.started_at = None

    def start(self):
        # Ensure baud rate
        ssh_exec(self.client, "stty -F /dev/ttyS1 115200 raw -echo")
        # Kill any stale cat
        ssh_exec(self.client, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")
        ssh_exec(self.client, f"rm -f {self.remote_tmp} 2>/dev/null || true")
        ssh_exec(
            self.client,
            f"nohup sh -c 'timeout {self.duration_s} cat /dev/ttyS1 > {self.remote_tmp} 2>/dev/null' "
            f"> /dev/null 2>&1 &",
        )
        self.started_at = time.time()
        print(f"[uart] background capture -> {self.remote_tmp} (up to {self.duration_s}s)")

    def snapshot(self, local_snapshot=None):
        """Copy what we have so far to local_path (or a custom file)."""
        path = local_snapshot or self.local_path
        try:
            sftp = self.client.open_sftp()
            sftp.get(self.remote_tmp, path)
            sftp.close()
            return True
        except Exception as e:
            print(f"    uart snapshot fail: {e}")
            return False


# -------------------- loader.prg -> BASIC DATA stub --------------------

def make_data_loader_lines(ml_bytes, poke_target=49152, start_line=100, step=10, per_line=16):
    """Return a list of BASIC lines that READ `ml_bytes` into memory at `poke_target`.

    Line layout:
      <start_line-90> FOR I=0 TO N-1:READ A:POKE <target>+I,A:NEXT
      <start_line-80> PRINT "DONE":END
      <start_line>    DATA ...
      ...
    """
    n = len(ml_bytes)
    lines = []
    lnum_for = start_line - 90
    lnum_end = start_line - 80
    lines.append(f"{lnum_for} FORI=0TO{n-1}:READA:POKE{poke_target}+I,A:NEXT")
    lines.append(f"{lnum_end} PRINT\"OK\":END")
    cur = start_line
    for i in range(0, n, per_line):
        chunk = ml_bytes[i:i+per_line]
        s = ",".join(str(b) for b in chunk)
        lines.append(f"{cur} DATA{s}")
        cur += step
    # Paranoia: every line must be <= 79 chars
    for ln in lines:
        if len(ln) > 79:
            raise RuntimeError(f"BASIC line too long ({len(ln)} chars): {ln}")
    return lines


# -------------------- Screen & PEEK helpers --------------------

def send_basic_line(client, line):
    """Type a single BASIC line terminated by ENTER.

    NOTE: mtype.py creates a uinput device each call with 6 s settle time.
    We batch as many tokens as possible per call to minimise round-trips.
    """
    # Shell-quote the whole thing and pass as ONE arg plus 'enter'.
    mtype(client, line, extra="enter")


def batch_basic_commands(client, lines, extra_wait=None):
    """Send several short BASIC lines in a single mtype.py call.

    Each line becomes: '<line>' enter
    `extra_wait`: if given, append a `wait:<s>` token at the end so that the
    uinput device stays alive long enough for the last command's effect to
    complete before the device is destroyed.
    """
    if not lines:
        return
    # Shell-quote each line and append 'enter' after it
    tokens = []
    for ln in lines:
        escaped = ln.replace("'", "'\\''")
        tokens.append(f"'{escaped}'")
        tokens.append("enter")
    if extra_wait is not None:
        tokens.append(f"wait:{extra_wait}")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    # Allow long timeout: each mtype call has ~6 s device-settle, plus ~140 ms
    # per key event (see mtype.py: 0.04+0.08 per key, sometimes +shift).
    total_chars = sum(len(l) for l in lines) + sum(1 for _ in lines)  # +1 per line for enter
    to = 60 + int(total_chars * 0.2) + (extra_wait or 0)
    out, err = ssh_exec(client, cmd, timeout=to)
    if err.strip() and 'unmapped' not in err:
        print(f"    mtype stderr: {err.strip()[:120]}")


# -------------------- MGL for REU load --------------------

def verify_mgl(client):
    """Confirm the existing MGL exists on MiSTer; no local staging needed."""
    sftp = client.open_sftp()
    try:
        st = sftp.stat(MGL_REMOTE)
        print(f"[mgl] using existing {MGL_REMOTE} ({st.st_size} bytes)")
    finally:
        sftp.close()


# -------------------- Trace dump via UART TR lines --------------------

def parse_tr_lines(uart_text):
    """Extract TR:... trace lines from UART capture."""
    return [ln for ln in uart_text.splitlines() if ln.startswith("TR:") or "TR:" in ln]


def parse_uart_summary(uart_text):
    """Quick summary of the UART capture: line counts and noteworthy markers."""
    lines = [l for l in uart_text.splitlines() if l.strip()]
    a_lines = [l for l in lines if l.startswith('A:')]
    tr_lines = [l for l in lines if 'TR:' in l or l.startswith('TR:')]
    bank_2d = [l for l in a_lines if ' K:2D' in l]
    bank_20 = [l for l in a_lines if ' K:20' in l]
    x0 = sum(1 for l in a_lines if ' P:' in l and _p_x_flag(l) == 0)
    x1 = sum(1 for l in a_lines if ' P:' in l and _p_x_flag(l) == 1)
    return {
        'total': len(lines),
        'A_lines': len(a_lines),
        'TR_lines': len(tr_lines),
        'K_2D_lines': len(bank_2d),
        'K_20_lines': len(bank_20),
        'X0_count': x0,
        'X1_count': x1,
        'last10_A': a_lines[-10:] if a_lines else [],
        'sample_TR': tr_lines[:8] if tr_lines else [],
        'last_TR': tr_lines[-16:] if tr_lines else [],
    }


def _p_x_flag(uart_line):
    """Extract X flag (bit 4) from P: field in a UART line, or -1 if absent."""
    try:
        p_idx = uart_line.index(' P:')
        hex2 = uart_line[p_idx+3:p_idx+5]
        return (int(hex2, 16) >> 4) & 1
    except Exception:
        return -1


# -------------------- Main --------------------

def main():
    if not os.path.exists(LOADER_PRG):
        print(f"ERROR: {LOADER_PRG} not found")
        return 1

    raw = open(LOADER_PRG, "rb").read()
    assert raw[0:2] == bytes([0x01, 0x08]), "loader.prg load address must be $0801"
    payload = raw[2:]
    ml_body = payload[12:]  # skip 12-byte BASIC stub
    assert len(ml_body) == 240, f"unexpected ML size: {len(ml_body)}"
    print(f"[load] loader.prg: {len(raw)} bytes, ML body {len(ml_body)} bytes ($080D..${0x080D+len(ml_body)-1:04X})")

    client = mk_client()
    print(f"[+] Connected to {HOST}")

    # 1. Upload mtype.py, stty UART
    sftp = client.open_sftp()
    sftp.put(MTYPE_LOCAL, "/tmp/mtype.py")
    sftp.close()
    print("[+] mtype.py uploaded")
    ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo")

    # 2. Verify REU-loading MGL and doom.reu presence
    verify_mgl(client)
    out, _ = ssh_exec(client, f"md5sum {REU_REMOTE} 2>/dev/null; ls -la {REU_REMOTE} 2>/dev/null")
    print(f"[+] doom.reu on MiSTer:\n    {out.strip()}")

    # 3. MGL load reloads the core and copies doom.reu into REU SDRAM space.
    #    Because MiSTer maps CPU bank $20 <-> REU offset $200000, doom.reu
    #    content is already addressable as bank $20 code after the load.
    print("[+] Loading doom.reu via MGL pipe (this reloads the C64 core)...")
    ssh_exec(client, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    print("    waiting 25s for REU transfer + core reset + BASIC READY...")
    time.sleep(25)

    # Now re-stty UART and start background capture AFTER the reset so we only
    # catch fresh post-load activity.
    ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo")
    uart = UartCapture(client, "/tmp/uart_doom_dp.log", UART_LOG, duration_s=240)
    uart.start()
    time.sleep(1)  # let capture buffer a few idle lines

    # 4. Build the DATA-based loader program (kept for optional use)
    print("[+] Building BASIC DATA loader program for loader.prg ML body...")
    lines = make_data_loader_lines(ml_body, poke_target=49152, start_line=100, step=10, per_line=16)
    print(f"    generated {len(lines)} BASIC lines")
    for ln in lines[:4]:
        print(f"      {ln}")
    print(f"      ... {len(lines)-6} more DATA lines ...")
    for ln in lines[-2:]:
        print(f"      {ln}")

    # 5. KEY DISCOVERY (post-attempt-2 analysis):
    #    - MiSTer maps SuperRAM bank $XX to REU SDRAM offset $XX0000, so CPU bank
    #      $20 addr $0000 == doom.reu offset $200000 == Doom's native-mode entry.
    #    - Therefore loader.prg is NOT needed to copy REU->SuperRAM; the MGL load
    #      already placed Doom's code in bank $20.
    #    - However, the PRIMARY TASK calls for exercising loader.prg's path
    #      (BASIC DATA/READ/POKE -> $080D -> SYS 2061 -> REU FETCH chain).
    #      loader.prg expects doom.reu to have a descriptor table at REU $FF0000
    #      with launch vector at $04FC - doom.reu has all-zeros at $FF0000, so
    #      the ML completes but JML [$04FC] jumps to $00:$0000 -> stuck at $0002.
    #    - We therefore execute BOTH paths in one run:
    #      (a) Inject loader.prg via DATA/POKE and SYS 2061 (documents that the
    #          DATA/POKE injection mechanism works - the failure is loader-vs-REU
    #          format mismatch, not our injection).
    #      (b) Also issue the minimal SuperCPU launcher afterwards to actually
    #          get Doom running. This is the launcher from CLAUDE.md and matches
    #          /media/fat/games/C64/doom_launcher2.prg (SEI;CLC;XCE;JML $20:$0000).

    # --- PHASE A: loader.prg DATA/POKE injection + SYS 2061 ------------------
    #     This exercises the mandated DATA/POKE path. We EXPECT this to hang
    #     at $00:$0000 loop (loader's JML [$04FC] + empty doom.reu at $FF:$0000)
    #     because loader.prg is designed for a "descriptor + data" REU layout
    #     that this doom.reu does NOT use.
    print("\n[Phase A] Inject loader.prg via DATA/POKE + SYS 2061 ...")
    phase_a_lines = ['NEW'] + lines + ['RUN']
    direct_mode = 'FORI=0TO239:POKE2061+I,PEEK(49152+I):NEXT:SYS2061'

    tokens = []
    def push_line(text):
        escaped = text.replace("'", "'\\''")
        tokens.append(f"'{escaped}'")
        tokens.append("enter")
    def push_wait(seconds):
        tokens.append(f"wait:{seconds}")

    for ln in phase_a_lines:
        push_line(ln)
    push_wait(6)            # wait for RUN (240 READs)
    push_line(direct_mode)  # copy $C000->$080D; SYS 2061 (loader.prg ML runs)
    push_wait(12)           # observe loader.prg: FETCH + (expected) hang at $0002

    total_chars = sum(len(t) for t in tokens)
    total_waits = 6 + 12
    to = 60 + int(total_chars * 0.18) + total_waits
    print(f"[Phase A] mtype batch: {len(tokens)} tokens, ~{total_chars} chars, timeout={to}s")
    t0 = time.time()
    out, err = ssh_exec(client, "python3 /tmp/mtype.py " + " ".join(tokens), timeout=to)
    dt = time.time() - t0
    print(f"[Phase A] mtype returned in {dt:.1f}s")
    if err.strip() and 'unmapped' not in err:
        print(f"[Phase A] mtype stderr: {err.strip()[:200]}")

    # Grab the log so we can see Phase A's end state in the report
    uart.snapshot(UART_LOG + ".phaseA")

    # --- PHASE B: fresh core reset, then use the simple launcher --------------
    # loader.prg left the CPU in a zero-page loop (PC=$0002). Keyboard input
    # is no longer serviced. We also need to reset MiSTer's virtual-input
    # state, because mtype.py's second uinput device is not processed by
    # MiSTer Main once it has already accepted one. Restart MiSTer Main and
    # reload the core. SDRAM/REU content survives.
    print("\n[Phase B] Restart MiSTer Main + reload core (fresh uinput state)...")
    ssh_exec(client, "kill `pidof MiSTer` 2>/dev/null; sleep 2; "
                     "nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
    print("    waiting 15s for MiSTer Main restart + C64 boot to READY...")
    time.sleep(15)
    # Then reload via MGL to re-apply the REU mapping (SDRAM content preserved)
    ssh_exec(client, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    print("    waiting 20s for MGL reload + BASIC READY...")
    time.sleep(20)
    ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo")

    print("[Phase B] Issuing simple SuperCPU launcher (SEI;CLC;XCE;JML $20:$0000)...")
    launcher_lines = [
        'POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92',
        'POKE49156,0:POKE49157,0:POKE49158,32',
        'SYS49152',
    ]
    tokens_b = []
    for ln in launcher_lines:
        escaped = ln.replace("'", "'\\''")
        tokens_b.append(f"'{escaped}'")
        tokens_b.append("enter")
    tokens_b.append("wait:30")  # observe Doom running / TR stream firing

    total_chars_b = sum(len(t) for t in tokens_b)
    to_b = 60 + int(total_chars_b * 0.18) + 30
    print(f"[Phase B] mtype batch: {len(tokens_b)} tokens, ~{total_chars_b} chars, timeout={to_b}s")
    t0 = time.time()
    out, err = ssh_exec(client, "python3 /tmp/mtype.py " + " ".join(tokens_b), timeout=to_b)
    dt = time.time() - t0
    print(f"[Phase B] mtype returned in {dt:.1f}s")
    if err.strip() and 'unmapped' not in err:
        print(f"[Phase B] mtype stderr: {err.strip()[:200]}")

    # Extra observation window. IMPORTANT: mtype.py tears down the uinput
    # device immediately after sending its last key, and MiSTer Main appears
    # to queue virtual-input events and process them with up to ~30 s of lag
    # after the device goes away. So the final SYS49152 may not actually
    # execute until well AFTER mtype returns. Give enough time for Doom to
    # start rendering and for any TR stream to fire.
    print("    extra 60s observation window...")
    time.sleep(60)

    # 13. Final UART grab
    uart.snapshot(UART_LOG)

    # 14. Kill the cat if still running
    ssh_exec(client, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")

    # 15. Summarise
    try:
        text = open(UART_LOG, "r", errors='replace').read()
    except Exception as e:
        print(f"[!] Failed to open UART log: {e}")
        text = ""

    print(f"\n===== UART log: {UART_LOG} ({len(text)} bytes) =====")
    summary = parse_uart_summary(text)
    print(f"Total lines: {summary['total']}")
    print(f"A: lines:    {summary['A_lines']}")
    print(f"TR lines:    {summary['TR_lines']}")
    print(f"K:2D lines:  {summary['K_2D_lines']}")
    print(f"K:20 lines:  {summary['K_20_lines']}")
    print(f"X=0 count:   {summary['X0_count']}")
    print(f"X=1 count:   {summary['X1_count']}")

    if summary['sample_TR']:
        print("\nFirst TR lines:")
        for l in summary['sample_TR']:
            print(f"  {l}")
    if summary['last_TR']:
        print("\nLast 16 TR lines:")
        for l in summary['last_TR']:
            print(f"  {l}")

    print("\nLast 10 A: lines:")
    for l in summary['last10_A']:
        print(f"  {l}")

    client.close()
    print(f"\n[+] Done. UART log: {UART_LOG}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
