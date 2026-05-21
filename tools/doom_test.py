#!/usr/bin/env python3
"""Launch doom via PRG loader and capture UART diagnostics."""
import paramiko, time, sys

HOST = '192.168.50.130'

def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=10)

    # Ensure mtype.py is uploaded
    sftp = c.open_sftp()
    try:
        sftp.stat('/tmp/mtype.py')
    except FileNotFoundError:
        sftp.put('tools/mtype.py', '/tmp/mtype.py')
        print("[+] Uploaded mtype.py")
    sftp.close()

    # Configure UART
    c.exec_command('stty -F /dev/ttyS1 115200 raw -echo')
    time.sleep(0.5)

    # Start UART capture (30 seconds)
    c.exec_command('timeout 30 cat /dev/ttyS1 > /tmp/uart_doom_test.log 2>/dev/null &')
    time.sleep(0.5)
    print("[+] UART capture started (30 sec)")

    # Type SYS49152 + enter via mtype
    print("[+] Typing SYS49152...")
    c.exec_command('python3 /tmp/mtype.py SYS49152 enter')
    time.sleep(10)
    print("[+] SYS49152 sent")

    # Take screenshot
    c.exec_command('echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2)
    print("[+] Screenshot taken")

    # Wait for UART capture to finish
    print("[+] Waiting for UART capture to complete...")
    time.sleep(20)

    # Retrieve UART log
    _, out, _ = c.exec_command('wc -l /tmp/uart_doom_test.log')
    lines = out.read().decode().strip()
    print(f"UART lines: {lines}")

    _, out, _ = c.exec_command('head -20 /tmp/uart_doom_test.log')
    print("First 20 lines:")
    print(out.read().decode())

    _, out, _ = c.exec_command('tail -20 /tmp/uart_doom_test.log')
    print("Last 20 lines:")
    print(out.read().decode())

    # Find native mode entries (E: != 1)
    _, out, _ = c.exec_command("grep -v 'E:1 ' /tmp/uart_doom_test.log | head -20")
    native = out.read().decode()
    if native:
        print("=== Native mode entries (E:!=1) ===")
        print(native)
    else:
        print("No native mode entries found (all E:1)")

    # Look for non-standard T values
    _, out, _ = c.exec_command("grep -v 'T:21' /tmp/uart_doom_test.log | head -20")
    t_changes = out.read().decode()
    if t_changes:
        print("=== Non-T:21 entries ===")
        print(t_changes)
    else:
        print("All entries T:21 (normal BASIC idle)")

    # Check for bank != 00
    _, out, _ = c.exec_command("grep -v 'B:00' /tmp/uart_doom_test.log | head -20")
    bank = out.read().decode()
    if bank:
        print("=== Non-bank-00 entries ===")
        print(bank)

    c.close()
    print("[+] Done")

if __name__ == '__main__':
    main()
