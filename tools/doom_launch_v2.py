#!/usr/bin/env python3
"""doom_launch_v2.py — single-mtype Doom launch via ABS-path MGL.

Sequence:
  1. Restart MiSTer main (fresh mtype state + fresh core boot).
  2. MGL-load doom.reu using ABS-path MGL (fixes relative-path bug).
  3. Wait for core ready + REU load (~35s).
  4. Start UART capture in background.
  5. Single mtype: POKE the SEI/CLC/XCE/JML $20:$0000 launcher, SYS49152.
  6. Observe UART + HDMI for Doom running.
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
UART_LOG = os.path.join(PROJECT_ROOT, f"uart_doom_v2_{TIMESTAMP}.log")


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

    # Upload mtype + MGL
    sftp = c.open_sftp()
    sftp.put(MTYPE_LOCAL, "/tmp/mtype.py")
    sftp.put(MGL_LOCAL, MGL_REMOTE)
    sftp.close()
    print(f"[+] Uploaded mtype.py + {MGL_REMOTE}")

    # Restart MiSTer main fresh
    print("[+] Restarting MiSTer Main (fresh state)...")
    ssh_exec(c, "kill `pidof MiSTer` 2>/dev/null ; sleep 1 ; "
                "nohup /media/fat/MiSTer /media/fat/_Test/C64.rbf > /tmp/mister.log 2>&1 &")
    time.sleep(10)

    # MGL-load doom.reu via pipe (ABS path)
    print("[+] MGL-loading doom.reu (abs path)...")
    ssh_exec(c, f"echo 'load_core {MGL_REMOTE}' > /dev/MiSTer_cmd")
    print("    waiting 35s for REU transfer + BASIC ready...")
    time.sleep(35)

    # Set UART and start capture
    ssh_exec(c, "stty -F /dev/ttyS1 115200 raw -echo")
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")
    ssh_exec(c, "rm -f /tmp/uart_doom_v2.log")
    ssh_exec(c, "nohup sh -c 'timeout 180 cat /dev/ttyS1 > /tmp/uart_doom_v2.log 2>/dev/null' "
                "> /dev/null 2>&1 &")
    print("[+] UART capture started (180s window)")

    # Single mtype call: sanity-check PEEK + launcher
    # Line <=40 chars each to avoid BASIC line-limit issues.
    lines = [
        'POKE49152,120:POKE49153,24',
        'POKE49154,251:POKE49155,92',
        'POKE49156,0:POKE49157,0',
        'POKE49158,32',
        'SYS49152',
    ]
    tokens = []
    for ln in lines:
        tokens.append("'" + ln + "'")
        tokens.append('enter')
    tokens.append('wait:60')  # observe Doom running post-launch
    cmd_mtype = "python3 /tmp/mtype.py " + " ".join(tokens)
    print("[+] Launching (single mtype call)...")
    t0 = time.time()
    out, err = ssh_exec(c, cmd_mtype, timeout=240)
    dt = time.time() - t0
    print(f"[+] mtype returned in {dt:.1f}s")
    if err.strip() and 'unmapped' not in err:
        print(f"    mtype stderr: {err.strip()[:200]}")

    # Extra observation window
    print("[+] Extra 90s observation window...")
    time.sleep(90)

    # Fetch UART
    sftp = c.open_sftp()
    try:
        sftp.get("/tmp/uart_doom_v2.log", UART_LOG)
        print(f"[+] UART log saved to {UART_LOG}")
    except Exception as e:
        print(f"    uart fetch fail: {e}")
    sftp.close()

    # Kill cat
    ssh_exec(c, "pkill -f 'cat /dev/ttyS1' 2>/dev/null || true")

    # Summary
    try:
        text = open(UART_LOG).read()
    except Exception:
        text = ""
    lines = [l for l in text.splitlines() if l.strip()]
    a_lines = [l for l in lines if l.startswith('A:')]
    tr_lines = [l for l in lines if 'TR:' in l]
    k20 = sum(1 for l in a_lines if ' K:20' in l)
    k00 = sum(1 for l in a_lines if ' K:00' in l)
    k2d = sum(1 for l in a_lines if ' K:2D' in l)
    print(f"\n===== UART summary: {len(text)} bytes, {len(lines)} lines =====")
    print(f"A: lines: {len(a_lines)}  TR lines: {len(tr_lines)}")
    print(f"K:20: {k20}  K:00: {k00}  K:2D: {k2d}")
    if a_lines:
        print("\nFirst 5 A: lines:")
        for l in a_lines[:5]:
            print(f"  {l}")
        print("\nLast 10 A: lines:")
        for l in a_lines[-10:]:
            print(f"  {l}")

    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
