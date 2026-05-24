#!/usr/bin/env python3
"""
d072_throttle_test.py — validate $D072 throttle gate (build after fpga64 cpu_cyc edit)

Phase 1: Boot smoke test (KERNAL READY).
Phase 2: POKE 53362,0 (assert $D072 = sys 1MHz on), then LOAD"*",8,1 and watch
         for change/no-wedge.
Phase 3: Run scpu_speed_bench.prg — expects distinct counts for slow vs fast
         phases (previously all 4 returned identical $00064F).

Outputs go to tools/d072_throttle_test/<name>.png.
"""
import os
import sys
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
TEST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "d072_throttle_test")
os.makedirs(TEST_DIR, exist_ok=True)


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS, timeout=10,
                look_for_keys=False, allow_agent=False)
    return ssh


def run_cmd(ssh, cmd, timeout=30):
    _, stdout, stderr = ssh.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    return out, err


def screenshot(ssh, name):
    path = os.path.join(TEST_DIR, name)
    run_cmd(ssh, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    # Pull latest screenshot
    out, _ = run_cmd(ssh, "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    latest = out.strip().splitlines()[0] if out.strip() else None
    if not latest:
        print(f"  ! no screenshot for {name}")
        return None
    sftp = ssh.open_sftp()
    sftp.get(latest, path)
    sftp.close()
    print(f"  shot -> {name}")
    return path


def mtype(ssh, *args, settle=0.5):
    """Run mtype.py with literal args; quote each separately."""
    quoted = " ".join(f"'{a}'" for a in args)
    run_cmd(ssh, f"python3 /tmp/mtype.py {quoted}")
    time.sleep(settle)


def main():
    ssh = ssh_connect()
    print("=== d072 throttle test ===")

    # Ensure mtype.py is uploaded
    sftp = ssh.open_sftp()
    sftp.put("tools/mtype.py", "/tmp/mtype.py")
    sftp.close()
    run_cmd(ssh, "chmod +x /tmp/mtype.py")

    # Pull current UART
    print("Current UART (before reload):")
    out, _ = run_cmd(ssh, "timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -3")
    print(out)

    # Reload C64 core (fresh KERNAL boot)
    print("\nReloading C64 core...")
    run_cmd(ssh, "echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd")
    time.sleep(10)
    screenshot(ssh, "00_boot.png")

    # Set UART baud
    run_cmd(ssh, "stty -F /dev/ttyS1 115200 raw -echo")
    out, _ = run_cmd(ssh, "timeout 1 cat /dev/ttyS1 2>/dev/null | tail -1")
    print(f"UART: {out.strip()}")

    # Phase 1: smoke test BASIC works at all
    print("\n--- Phase 1: BASIC smoke test ---")
    mtype(ssh, "PRINT", "space", "\"THROTTLE", "TEST\"", "enter", settle=1.0)
    screenshot(ssh, "01_print.png")

    # Phase 2: POKE 53362,0 (=$D072 sys 1MHz) then LOAD
    print("\n--- Phase 2: POKE $D072=0 + LOAD ---")
    mtype(ssh, "POKE", "space", "53362,0", "enter", settle=1.0)
    screenshot(ssh, "02_poke_d072.png")

    # Now LOAD with the throttle active
    mtype(ssh, "LOAD", "\"*\",8,1", "enter", settle=2.0)
    screenshot(ssh, "03_load_t2s.png")
    time.sleep(8)
    screenshot(ssh, "04_load_t10s.png")
    time.sleep(15)
    screenshot(ssh, "05_load_t25s.png")
    time.sleep(30)
    screenshot(ssh, "06_load_t55s.png")

    # Read UART for status
    out, _ = run_cmd(ssh, "timeout 1 cat /dev/ttyS1 2>/dev/null | tail -1")
    print(f"\nUART after LOAD: {out.strip()}")

    # Phase 3: skip if LOAD wedged; otherwise reset and run bench
    print("\n--- Phase 3: speed bench (separate run) ---")
    print("Reload + run scpu_speed_bench.prg")
    run_cmd(ssh, "echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd")
    time.sleep(10)

    # Upload bench PRG
    sftp = ssh.open_sftp()
    sftp.put("tools/test_cart/out/scpu_speed_bench.prg", "/tmp/scpu_speed_bench.prg")
    sftp.close()
    run_cmd(ssh, "/media/fat/Scripts/.mbc/mbc load_rom /tmp/scpu_speed_bench.prg")
    time.sleep(3)
    mtype(ssh, "RUN", "enter", settle=8.0)
    screenshot(ssh, "07_bench_result.png")

    print(f"\nAll outputs in: {TEST_DIR}")
    ssh.close()


if __name__ == "__main__":
    main()
