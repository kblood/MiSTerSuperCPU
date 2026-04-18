#!/usr/bin/env python3
"""doom_launch_v5.py — use the doom_1mhz.prg launcher (disables CIAs + 1MHz).

This launcher:
  - SEI
  - Disables CIA1 + CIA2 IRQs
  - Switches to 1MHz via $D07A
  - 8x NOP delay
  - JML $20:$0000 (stays in emulation until Doom's own SEI/CLC/XCE)
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
UART_LOG = os.path.join(PROJECT_ROOT, f"uart_doom_v5_{TIMESTAMP}.log")


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

    print("[+] Restarting MiSTer Main + load doom_abs.mgl...")
    ssh_exec(c, "kill `pidof MiSTer` 2>/dev/null ; sleep 1 ; "
                "nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
    time.sleep(10)
    ssh_exec(c, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    time.sleep(35)

    # Load doom_1mhz.prg bytes
    with open(os.path.join(PROJECT_ROOT, "doom_1mhz.prg"), "rb") as f:
        raw = f.read()
    body = raw[2:]  # skip 2-byte load addr
    # Load addr is $C000; POKE the 32 bytes.
    print(f"[+] doom_1mhz.prg: {len(body)} bytes at $C000")

    ssh_exec(c, "stty -F /dev/ttyS1 115200 raw -echo")
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")
    ssh_exec(c, "rm -f /tmp/uart_doom_v5.log")
    ssh_exec(c, "nohup sh -c 'timeout 180 cat /dev/ttyS1 > /tmp/uart_doom_v5.log 2>/dev/null' "
                "> /dev/null 2>&1 &")

    # Build BASIC: DATA + FOR loop + SYS
    # 32 bytes = 1 DATA line of width 8 = 4 DATA lines
    lines = ['10 FORI=0TO31:READA:POKE49152+I,A:NEXT',
             '20 SYS49152']
    ln = 100
    per_line = 16
    for i in range(0, len(body), per_line):
        chunk = body[i:i+per_line]
        s = ",".join(str(b) for b in chunk)
        lines.append(f'{ln} DATA{s}')
        ln += 10

    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'RUN'")
    tokens.append('enter')
    tokens.append('wait:60')
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    total_chars = sum(len(l) for l in lines)
    to_s = 120 + int(total_chars * 0.2) + 60
    print(f"[+] typing launcher (timeout={to_s}s)...")
    t0 = time.time()
    out, err = ssh_exec(c, cmd, timeout=to_s)
    dt = time.time() - t0
    print(f"[+] mtype returned in {dt:.1f}s")

    time.sleep(60)

    sftp = c.open_sftp()
    try:
        sftp.get("/tmp/uart_doom_v5.log", UART_LOG)
        print(f"[+] UART log saved to {UART_LOG}")
    except Exception as e:
        print(f"fetch fail: {e}")
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
    for k in sorted(banks, key=lambda x: -banks[x])[:10]:
        print(f"  K:{k} = {banks[k]}")
    if aln:
        print("\nLast 5 A-lines:")
        for l in aln[-5:]: print(f"  {l}")
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
