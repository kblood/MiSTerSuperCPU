#!/usr/bin/env python3
"""Launch the Doom skip loader and capture UART diagnostics."""
import paramiko, time, threading, sys

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

def ssh_exec(client, cmd, timeout=10):
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors='replace')
    err = stderr.read().decode(errors='replace')
    return out, err

def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=10)
    print("[+] Connected to MiSTer")

    # Upload mtype.py
    sftp = client.open_sftp()
    sftp.put("tools/mtype.py", "/tmp/mtype.py")
    sftp.close()
    print("[+] mtype.py uploaded")

    # Step 1: Start UART capture to file in background
    out, err = ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo; echo OK")
    print(f"[+] UART configured: {out.strip()}")
    # Start background cat with timeout
    client.exec_command("timeout 20 cat /dev/ttyS1 > /tmp/uart_doom.log 2>/dev/null &")
    time.sleep(0.5)
    print("[+] UART capture started")

    # Step 2: Poke the skip loader bytes one short line at a time
    # CLC($18), XCE($FB), JML $200000($5C,$00,$00,$20) at $C000=49152
    # First clear any pending input with HOME + RETURN
    def mtype(text_arg, extra="enter"):
        """Send text + special key. text_arg is the text string, extra is appended as separate arg."""
        # Escape single quotes for shell
        escaped = text_arg.replace("'", "'\\''")
        cmd = f"python3 /tmp/mtype.py '{escaped}' {extra}"
        out, err = ssh_exec(client, cmd, timeout=20)
        if err.strip():
            print(f"  mtype err: {err.strip()[:80]}")

    print("[+] Typing POKE lines (SEI+CLC+XCE+JML $200000 at $C000)...")
    # Loader: SEI($78), CLC($18), XCE($FB), JML $200000($5C,$00,$00,$20)
    # SEI BEFORE XCE is critical: BASIC runs with IRQs enabled (I=0).
    # Without SEI first, native-mode switch exposes $FFEE/$FFEF as IRQ vector
    # (C64 KERNAL garbage), and CIA timer firing in next few cycles = instant crash.
    mtype("POKE49152,120:POKE49153,24:POKE49154,251")
    time.sleep(1.0)
    mtype("POKE49155,92:POKE49156,0:POKE49157,0:POKE49158,32")
    time.sleep(1.0)

    # Step 3: Verify bytes
    mtype("PRINT PEEK(49152);PEEK(49153);PEEK(49154);PEEK(49158)")
    time.sleep(2.0)

    # Step 4: Start UART capture right before launch
    client.exec_command("timeout 15 cat /dev/ttyS1 > /tmp/uart_doom.log 2>/dev/null &")
    time.sleep(0.3)
    print("[+] UART capture running, launching now...")

    # Step 5: Launch!
    mtype("SYS49152")
    time.sleep(10.0)  # Let game run for 10 seconds

    # Step 5: Read UART capture
    out, err = ssh_exec(client, "cat /tmp/uart_doom.log", timeout=5)
    print("\n=== UART CAPTURE ===")
    lines = out.strip().split('\n')
    print(f"Total lines: {len(lines)}")
    for line in lines:
        if line.strip():
            print(line)
    print("=== END UART ===")

    # Parse key fields
    print("\n=== ANALYSIS ===")
    for line in lines:
        if 'E:0' in line or 'B:20' in line or ('T:1 ' in line and 'T:21' not in line):
            print(f"NATIVE MODE: {line}")
    
    e_vals = set()
    b_vals = set()
    t_vals = set()
    for line in lines:
        for part in line.split():
            if part.startswith('E:'):
                e_vals.add(part)
            elif part.startswith('B:'):
                b_vals.add(part)
            elif part.startswith('T:'):
                t_vals.add(part)
    print(f"E values seen: {e_vals}")
    print(f"B values seen: {b_vals}")
    print(f"T values seen: {t_vals}")

    client.close()

if __name__ == '__main__':
    main()
