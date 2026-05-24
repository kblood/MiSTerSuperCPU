#!/usr/bin/env python3
"""
v8_iec_passthrough_test.py — probe whether bridge MCP causes the IEC LOAD wedge.

v8 RBF has SAME_CLOCK_PASSTHROUGH=1 → EFF_BRIDGE_ACTIVE=0 → pure passthrough.
This is the pre-MCP behavior (cpu_di_out=bus_di_in, cpu_rdy_out='1',
cpu_enable_out=enableCpu_816). $D072/$D07A throttle gate stays effective
because it lives in fpga64_sid_iec on cpu_cyc and propagates through the
ack pulse.

Probe sequence:
  1. Load core, confirm KERNAL READY.
  2. PRINT to confirm BASIC runs.
  3. LOAD"$",8 (directory) — fastest IEC handshake. If this completes,
     passthrough fixes the bridge-introduced IEC wedge.
  4. LOAD"*",8,1 (program) — full PRG load.
  5. (Optional) POKE 53362,0 + LOAD — verify throttle is still active.
  6. scpu_speed_bench.prg — measure turbo rate without throttle.

Outputs: tools/v8_iec_passthrough_test/<step>.png
"""
import os
import sys
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
TEST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "v8_iec_passthrough_test")
os.makedirs(TEST_DIR, exist_ok=True)


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS,
                timeout=10, look_for_keys=False, allow_agent=False)
    return ssh


def run_cmd(ssh, cmd, timeout=30):
    _, stdout, stderr = ssh.exec_command(cmd, timeout=timeout)
    return stdout.read().decode("utf-8", errors="replace"), \
           stderr.read().decode("utf-8", errors="replace")


def screenshot(ssh, name):
    path = os.path.join(TEST_DIR, name)
    run_cmd(ssh, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    out, _ = run_cmd(ssh,
        "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    latest = out.strip().splitlines()[0] if out.strip() else None
    if not latest:
        print(f"  ! no screenshot for {name}")
        return None
    sftp = ssh.open_sftp()
    sftp.get(latest, path)
    sftp.close()
    print(f"  shot -> {name}")
    return path


def uart_tail(ssh, lines=2):
    out, _ = run_cmd(ssh,
        f"timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -{lines}")
    return out.strip()


def mtype(ssh, *args, settle=0.5):
    quoted = " ".join(f"'{a}'" for a in args)
    run_cmd(ssh, f"python3 /tmp/mtype.py {quoted}")
    time.sleep(settle)


def mgl_load_disk(ssh, d64_path="/media/fat/games/C64/lorenz_disk1.d64"):
    """Mount a .d64 via MGL; replaces any prior mount."""
    mgl = f"""<mistergamedescription>
<rbf>_Test/C64</rbf>
<file delay="2" type="s" index="0" path="{d64_path}"/>
</mistergamedescription>
"""
    sftp = ssh.open_sftp()
    with sftp.open("/tmp/v8_iec.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    run_cmd(ssh, "echo load_core /tmp/v8_iec.mgl > /dev/MiSTer_cmd")
    time.sleep(12)


def main():
    ssh = ssh_connect()
    print("=== v8 IEC passthrough probe ===")

    # ensure mtype is in /tmp
    sftp = ssh.open_sftp()
    sftp.put("tools/mtype.py", "/tmp/mtype.py")
    sftp.close()
    run_cmd(ssh, "chmod +x /tmp/mtype.py")

    # check the v8 rbf md5 — must differ from v7 (0aa93cfd...)
    md5, _ = run_cmd(ssh, "md5sum /media/fat/_Test/C64.rbf 2>/dev/null")
    print(f"RBF: {md5.strip()}")

    # load core + mount disk
    print("\n--- Mounting Lorenz disk1 (has BASIC programs to LOAD) ---")
    mgl_load_disk(ssh)
    run_cmd(ssh, "stty -F /dev/ttyS1 115200 raw -echo")
    screenshot(ssh, "00_boot.png")
    print(f"UART: {uart_tail(ssh)}")

    # confirm CPU works
    print("\n--- Phase 1: BASIC smoke test ---")
    mtype(ssh, "PRINT", "space", "\"V8", "PASSTHRU\"", "enter", settle=1.0)
    screenshot(ssh, "01_print.png")

    # Phase 2 — the critical IEC test (no throttle)
    print("\n--- Phase 2: LOAD\"$\",8 (directory; fast IEC handshake) ---")
    mtype(ssh, "LOAD", "\"$\",8", "enter", settle=2.0)
    screenshot(ssh, "02_dirload_t2s.png")
    time.sleep(8)
    screenshot(ssh, "03_dirload_t10s.png")
    time.sleep(15)
    screenshot(ssh, "04_dirload_t25s.png")
    print(f"UART after dir LOAD: {uart_tail(ssh)}")

    # Phase 3 — full program LOAD
    print("\n--- Phase 3: NEW + LOAD\"*\",8,1 (program LOAD) ---")
    mtype(ssh, "NEW", "enter", settle=1.0)
    mtype(ssh, "LOAD", "\"*\",8,1", "enter", settle=2.0)
    screenshot(ssh, "05_progload_t2s.png")
    time.sleep(15)
    screenshot(ssh, "06_progload_t17s.png")
    time.sleep(20)
    screenshot(ssh, "07_progload_t37s.png")
    print(f"UART after prog LOAD: {uart_tail(ssh)}")

    # Phase 4 — throttle sanity (does $D072 still gate cpu_cyc?)
    print("\n--- Phase 4: throttle sanity (POKE 53362,0 + BASIC TI) ---")
    mtype(ssh, "NEW", "enter", settle=1.0)
    mtype(ssh, "POKE", "space", "53362,0", "enter", settle=0.5)
    mtype(ssh, "TI$=\"000000\":FORI=1TO500:NEXT:PRINTTI", "enter", settle=2.0)
    screenshot(ssh, "08_throttle_ti.png")
    time.sleep(35)
    screenshot(ssh, "09_throttle_ti_35s.png")
    print(f"UART after throttle TI: {uart_tail(ssh)}")

    print(f"\nAll outputs in: {TEST_DIR}")
    ssh.close()


if __name__ == "__main__":
    main()
