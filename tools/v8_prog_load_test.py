#!/usr/bin/env python3
"""
v8_prog_load_test.py — verify program LOAD"*",8,1 completes in v8 passthrough.

Phase 1: LOAD"*",8,1 at native turbo (no throttle).
Phase 2: POKE 53362,0 (force sys 1MHz) + LOAD"*",8,1.
Each phase waits up to 60s and screenshots every 10s.
"""
import os
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
TEST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "v8_prog_load_test")
os.makedirs(TEST_DIR, exist_ok=True)


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS,
                timeout=10, look_for_keys=False, allow_agent=False)
    return ssh


def run_cmd(ssh, cmd, timeout=30):
    _, stdout, _ = ssh.exec_command(cmd, timeout=timeout)
    return stdout.read().decode("utf-8", errors="replace")


def screenshot(ssh, name):
    path = os.path.join(TEST_DIR, name)
    run_cmd(ssh, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    out = run_cmd(ssh, "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    latest = out.strip().splitlines()[0] if out.strip() else None
    if not latest:
        return None
    sftp = ssh.open_sftp()
    sftp.get(latest, path)
    sftp.close()
    print(f"  shot -> {name}")
    return path


def uart_tail(ssh, lines=1):
    return run_cmd(ssh,
        f"timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -{lines}"
    ).strip()


def mtype(ssh, *args, settle=0.5):
    quoted = " ".join(f"'{a}'" for a in args)
    run_cmd(ssh, f"python3 /tmp/mtype.py {quoted}")
    time.sleep(settle)


def mgl_load_disk(ssh):
    mgl = ("<mistergamedescription>\n"
           "<rbf>_Test/C64</rbf>\n"
           "<file delay=\"2\" type=\"s\" index=\"0\" "
           "path=\"/media/fat/games/C64/lorenz_disk1.d64\"/>\n"
           "</mistergamedescription>\n")
    sftp = ssh.open_sftp()
    with sftp.open("/tmp/v8_iec.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    run_cmd(ssh, "echo load_core /tmp/v8_iec.mgl > /dev/MiSTer_cmd")
    time.sleep(12)


def main():
    ssh = ssh_connect()
    print("=== v8 program LOAD probe ===")
    sftp = ssh.open_sftp(); sftp.put("tools/mtype.py", "/tmp/mtype.py"); sftp.close()
    run_cmd(ssh, "chmod +x /tmp/mtype.py")

    print(f"RBF: {run_cmd(ssh, 'md5sum /media/fat/_Test/C64.rbf').strip()}")

    print("\n=== PHASE 1: native turbo + LOAD\"*\",8,1 ===")
    mgl_load_disk(ssh)
    run_cmd(ssh, "stty -F /dev/ttyS1 115200 raw -echo")
    screenshot(ssh, "p1_00_boot.png")
    mtype(ssh, "LOAD", "\"*\",8,1", "enter", settle=1.0)
    for i, t in enumerate([2, 10, 20, 30, 45, 60]):
        time.sleep(t - (0 if i == 0 else [2,10,20,30,45,60][i-1]))
        screenshot(ssh, f"p1_t{t:02d}s.png")
        print(f"  t={t}s UART: {uart_tail(ssh)[:120]}")

    print("\n=== PHASE 2: POKE 53362,0 + LOAD\"*\",8,1 (with throttle) ===")
    mgl_load_disk(ssh)
    screenshot(ssh, "p2_00_boot.png")
    mtype(ssh, "POKE", "space", "53362,0", "enter", settle=1.0)
    screenshot(ssh, "p2_01_poked.png")
    mtype(ssh, "LOAD", "\"*\",8,1", "enter", settle=1.0)
    for i, t in enumerate([2, 10, 20, 30, 45, 60, 90]):
        prev = 0 if i == 0 else [2,10,20,30,45,60,90][i-1]
        time.sleep(t - prev)
        screenshot(ssh, f"p2_t{t:02d}s.png")
        print(f"  t={t}s UART: {uart_tail(ssh)[:120]}")

    print(f"\nOutputs in {TEST_DIR}")
    ssh.close()


if __name__ == "__main__":
    main()
