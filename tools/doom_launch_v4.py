#!/usr/bin/env python3
"""doom_launch_v4.py — full-chain: MGL loads reu+loader.prg, then SYS launcher.

doom_full_abs.mgl delay-loads doom.reu (index=1, REU) then doom_loader.prg
(index=1, PRG). The second file has a BASIC stub `SYS 2061` which auto-runs.
The loader.prg then:
  - Sets $D07A (1MHz switch off) and $D07B (turbo on) via its copy loop
  - Flashes border as progress indicator
  - Copies 16MB REU -> SuperRAM (redundant on MiSTer: same SDRAM)
  - Eventually exits via `DC FC 04 ... 00` which on NMOS/65C02 is NOP (3-byte)
    + BRK (0x00). BRK returns to BASIC READY.

After loader finishes (~10-20s), we then type the launcher POKE/SYS to jump
into native bank $20.
"""
import os, sys, time, paramiko
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MGL_LOCAL = os.path.join(PROJECT_ROOT, "tools", "_doom_full_abs.mgl")
MGL_REMOTE = "/media/fat/_Test/doom_full_abs.mgl"
MTYPE_LOCAL = os.path.join(PROJECT_ROOT, "tools", "mtype.py")

TIMESTAMP = time.strftime("%Y%m%d_%H%M%S")
UART_LOG = os.path.join(PROJECT_ROOT, f"uart_doom_v4_{TIMESTAMP}.log")


def mk_client():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10)
    return c


def ssh_exec(client, cmd, timeout=30):
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    return stdout.read().decode(errors='replace'), stderr.read().decode(errors='replace')


def main():
    c = mk_client()
    print(f"[+] Connected to {HOST}")

    sftp = c.open_sftp()
    sftp.put(MTYPE_LOCAL, "/tmp/mtype.py")
    sftp.put(MGL_LOCAL, MGL_REMOTE)
    sftp.close()
    print(f"[+] Uploaded mtype.py + {MGL_REMOTE}")

    print("[+] Restarting MiSTer Main...")
    ssh_exec(c, "kill `pidof MiSTer` 2>/dev/null ; sleep 1 ; "
                "nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
    time.sleep(10)

    print("[+] MGL-loading doom_full_abs.mgl (REU + loader.prg)...")
    ssh_exec(c, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    print("    waiting 60s for both files + loader.prg to run (it flashes border)...")
    time.sleep(60)

    # UART capture
    ssh_exec(c, "stty -F /dev/ttyS1 115200 raw -echo")
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")
    ssh_exec(c, "rm -f /tmp/uart_doom_v4.log")
    ssh_exec(c, "nohup sh -c 'timeout 180 cat /dev/ttyS1 > /tmp/uart_doom_v4.log 2>/dev/null' "
                "> /dev/null 2>&1 &")

    # Type the launcher POKE/SYS and wait
    launcher_lines = [
        'POKE49152,120:POKE49153,24',
        'POKE49154,251:POKE49155,92',
        'POKE49156,0:POKE49157,0',
        'POKE49158,32',
        'SYS49152',
    ]
    tokens = []
    for ln in launcher_lines:
        tokens.append("'" + ln + "'")
        tokens.append('enter')
    tokens.append('wait:120')
    cmd_mtype = "python3 /tmp/mtype.py " + " ".join(tokens)
    print("[+] Typing launcher (single mtype call)...")
    t0 = time.time()
    out, err = ssh_exec(c, cmd_mtype, timeout=360)
    dt = time.time() - t0
    print(f"[+] mtype returned in {dt:.1f}s")
    if err.strip() and 'unmapped' not in err:
        print(f"    mtype stderr: {err.strip()[:200]}")

    time.sleep(30)

    sftp = c.open_sftp()
    try:
        sftp.get("/tmp/uart_doom_v4.log", UART_LOG)
        print(f"[+] UART log saved to {UART_LOG}")
    except Exception as e:
        print(f"    fetch fail: {e}")
    sftp.close()
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")

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
        print("\nLast 5 A-lines:")
        for l in aln[-5:]: print(f"  {l}")

    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
