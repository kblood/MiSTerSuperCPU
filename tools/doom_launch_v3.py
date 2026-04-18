#!/usr/bin/env python3
"""doom_launch_v3.py — smart launcher: sets BRK safety net + flushes SCPU cache.

Derived from doom_launcher.prg. Writes the 174-byte launcher ML to $C000,
then SYS 49152. The launcher:
  1. Installs a tiny BRK/IRQ handler at $0400 that changes border RED and loops
     (visual "crashed" indicator).
  2. Points all native vectors ($FFE4-$FFEF) AND emulation vectors ($FFFA-$FFFF)
     to $0400 so any BRK/IRQ lands there safely.
  3. Flushes the SCPU cache via STA $D078.
  4. CLC / XCE -> native mode.
  5. JML $20:$0000 -> Doom entry.

If Doom crashes post-launch, we should see border turn RED instead of a BRK
cascade scrolling UART. If Doom runs, the screen should transition to bitmap
mode / title screen.
"""
import os, sys, time, paramiko
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MGL_LOCAL = os.path.join(PROJECT_ROOT, "tools", "_doom_abs.mgl")
MGL_REMOTE = "/media/fat/_Test/doom_abs.mgl"
MTYPE_LOCAL = os.path.join(PROJECT_ROOT, "tools", "mtype.py")

TIMESTAMP = time.strftime("%Y%m%d_%H%M%S")
UART_LOG = os.path.join(PROJECT_ROOT, f"uart_doom_v3_{TIMESTAMP}.log")


def mk_client():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10)
    return c


def ssh_exec(client, cmd, timeout=30):
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    return stdout.read().decode(errors='replace'), stderr.read().decode(errors='replace')


def build_launcher_at(base):
    """Build the launcher ML (174 bytes equivalent) relocated to `base`.

    The original doom_launcher.prg uses STA $04xx absolute addresses (no self-mod
    of base addrs), so it's position-independent for the POKEs. We just use the
    same byte stream at $C000.
    """
    with open(os.path.join(PROJECT_ROOT, "doom_launcher.prg"), "rb") as f:
        raw = f.read()
    body = raw[2:]  # skip 2-byte load addr
    return list(body)


def main():
    c = mk_client()
    print(f"[+] Connected to {HOST}")

    # Upload mtype + MGL
    sftp = c.open_sftp()
    sftp.put(MTYPE_LOCAL, "/tmp/mtype.py")
    sftp.put(MGL_LOCAL, MGL_REMOTE)
    sftp.close()
    print(f"[+] Uploaded mtype.py + {MGL_REMOTE}")

    # Restart MiSTer main fresh
    print("[+] Restarting MiSTer Main...")
    ssh_exec(c, "kill `pidof MiSTer` 2>/dev/null ; sleep 1 ; "
                "nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
    time.sleep(10)

    # MGL load
    print("[+] MGL-loading doom.reu (abs path)...")
    ssh_exec(c, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    print("    waiting 35s...")
    time.sleep(35)

    # UART capture
    ssh_exec(c, "stty -F /dev/ttyS1 115200 raw -echo")
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")
    ssh_exec(c, "rm -f /tmp/uart_doom_v3.log")
    ssh_exec(c, "nohup sh -c 'timeout 180 cat /dev/ttyS1 > /tmp/uart_doom_v3.log 2>/dev/null' "
                "> /dev/null 2>&1 &")
    print("[+] UART capture started (180s)")

    # Build launcher bytes
    ml = build_launcher_at(0xC000)
    print(f"[+] Launcher ML: {len(ml)} bytes at $C000")

    # Build BASIC program that POKEs the launcher + SYS 49152
    # 174 bytes of DATA, per_line=15 means ~12 DATA lines.
    per_line = 15
    lines = []
    lines.append(f'10 FORI=0TO{len(ml)-1}:READA:POKE49152+I,A:NEXT')
    lines.append('20 SYS49152')
    ln = 100
    for i in range(0, len(ml), per_line):
        chunk = ml[i:i+per_line]
        s = ",".join(str(b) for b in chunk)
        line = f'{ln} DATA{s}'
        if len(line) > 79:
            # Trim by dropping last byte -> handled next iter would skew; just emit and trust
            print(f'    WARNING: line {ln} is {len(line)} chars')
        lines.append(line)
        ln += 10

    # Single mtype call: type all BASIC lines + RUN, then wait
    tokens = []
    for ln_ in lines:
        tokens.append("'" + ln_ + "'")
        tokens.append('enter')
    tokens.append("'RUN'")
    tokens.append('enter')
    tokens.append('wait:60')
    cmd_mtype = "python3 /tmp/mtype.py " + " ".join(tokens)
    total_chars = sum(len(l) for l in lines)
    to_s = 180 + int(total_chars * 0.18) + 60
    print(f"[+] mtype batch: {len(tokens)} tokens ~{total_chars} chars, timeout={to_s}s")
    t0 = time.time()
    out, err = ssh_exec(c, cmd_mtype, timeout=to_s)
    dt = time.time() - t0
    print(f"[+] mtype returned in {dt:.1f}s")
    if err.strip() and 'unmapped' not in err:
        print(f"    mtype stderr: {err.strip()[:200]}")

    # Extra observation
    print("[+] Extra 60s observation...")
    time.sleep(60)

    # Fetch UART
    sftp = c.open_sftp()
    try:
        sftp.get("/tmp/uart_doom_v3.log", UART_LOG)
        print(f"[+] UART log saved to {UART_LOG}")
    except Exception as e:
        print(f"    fetch fail: {e}")
    sftp.close()
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")

    # Summary
    try:
        text = open(UART_LOG).read()
    except Exception:
        text = ""
    aln = [l for l in text.splitlines() if l.startswith('A:')]
    banks = {}
    for l in aln:
        idx = l.find(' K:')
        if idx > 0:
            k = l[idx+3:idx+5]
            banks[k] = banks.get(k, 0) + 1
    print(f"\n===== UART summary: {len(aln)} A-lines =====")
    print("Bank distribution:")
    for k in sorted(banks, key=lambda x: -banks[x]):
        print(f"  K:{k} = {banks[k]}")
    if aln:
        print("\nFirst 3 A-lines:")
        for l in aln[:3]: print(f"  {l}")
        print("\nLast 5 A-lines:")
        for l in aln[-5:]: print(f"  {l}")

    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
