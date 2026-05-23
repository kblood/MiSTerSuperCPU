#!/usr/bin/env python3
"""Sweep OSD turbo settings and capture cpu_bound_bench COUNT.

For each turbo (off / smart / full) at speed=4x:
  1. Edit C64.cfg byte 5 (turbo mode), byte 6 (turbo speed) on MiSTer
  2. load_core C64 (reloads bitstream + reads new cfg)
  3. Wait for KERNAL READY
  4. load_prg cpu_bound_bench.prg via mbc
  5. Type RUN
  6. Wait for several measurement passes
  7. Screenshot -> bench_turbo_<label>.png

Output: side-by-side COUNT comparison.
"""
import os
import sys
import time
import paramiko

MISTER_IP = "192.168.50.130"
USER = "root"
PASS = "1"
CFG_PATH = "/media/fat/config/C64.cfg"
PRG_LOCAL = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "out", "cpu_bound_bench.prg"))
PRG_REMOTE = "/media/fat/games/C64/cpu_bound_bench.prg"
SCREENSHOT_DIR_LOCAL = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "out"))

# 16-byte canonical SCPU+REU16M cfg, byte 5 = turbo mode, byte 6 = speed+REU
# Per CLAUDE.md / wolf3d_turbo_test pattern:
#   byte 5: 0x00=off, 0x40=smart, 0x80=full
#   byte 6: 0x62 = 4x speed + REU 16MB
CFG_BASE = bytes([
    0x00, 0x40, 0x00, 0x00, 0x00,  # 0-4
    0x00,                            # 5 = turbo mode (PATCH)
    0x62,                            # 6 = turbo speed + REU
    0x00, 0x00, 0x00,                # 7-9
    0x1C,                            # 10 = SCPU/UART/overlay flags
    0x00, 0x00, 0x00, 0x00, 0x00,
])

SWEEP = [
    ("off",     0x00),
    ("smart4x", 0x40),
    ("full4x",  0x80),
]


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER_IP, username=USER, password=PASS)
    return c


def run(c, cmd, timeout=30):
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    return stdout.read().decode(errors="replace"), stderr.read().decode(errors="replace")


def write_cfg(c, turbo_byte):
    cfg = bytearray(CFG_BASE)
    cfg[5] = turbo_byte
    sftp = c.open_sftp()
    with sftp.open(CFG_PATH, "wb") as f:
        f.write(bytes(cfg))
    sftp.close()


def upload_prg(c):
    sftp = c.open_sftp()
    sftp.put(PRG_LOCAL, PRG_REMOTE)
    sftp.close()


def load_core(c):
    # MGL with no rbf — defaults to current /media/fat/_Test/C64.rbf
    cmd = "echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd"
    run(c, cmd)


def load_prg(c):
    # Use mbc to inject PRG into running C64 (core name = "C64.PRG" with dot)
    run(c, f"mbc load_rom C64.PRG {PRG_REMOTE}")


def type_keys(c, keys):
    run(c, f"python3 /tmp/mtype.py {keys}")


def screenshot(c, local_path):
    run(c, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(1.5)
    # Find newest screenshot
    out, _ = run(c, "ls -t /media/fat/screenshots/C64/ | head -1")
    name = out.strip()
    if not name:
        print("  ! no screenshot found")
        return False
    sftp = c.open_sftp()
    sftp.get(f"/media/fat/screenshots/C64/{name}", local_path)
    sftp.close()
    return True


def sweep(c):
    results = []
    for label, byte5 in SWEEP:
        print(f"\n== turbo={label} (byte5=0x{byte5:02X}) ==")
        write_cfg(c, byte5)
        load_core(c)
        print("  load_core sent — waiting 14s for boot...")
        time.sleep(14)
        load_prg(c)
        print("  PRG injected — waiting 2s...")
        time.sleep(2)
        # SYS 2061 — direct jump to $080D bench entry.
        # (Avoids RUN which can fail if mbc didn't fix up BASIC pointers.)
        type_keys(c, "sys 2061 enter")
        print("  typed RUN — waiting 15s for measurement settle...")
        time.sleep(15)
        out = os.path.join(SCREENSHOT_DIR_LOCAL, f"bench_turbo_{label}.png")
        if screenshot(c, out):
            print(f"  screenshot -> {out}")
            results.append((label, out))
    return results


def main():
    if not os.path.exists(PRG_LOCAL):
        print(f"ERROR: PRG not built at {PRG_LOCAL}")
        print("Run: python tools/test_cart/gen_cpu_bound_bench.py")
        sys.exit(1)
    c = ssh()
    try:
        upload_prg(c)
        print(f"Uploaded {PRG_LOCAL} -> {PRG_REMOTE}")
        results = sweep(c)
        print("\n=== RESULTS ===")
        for label, path in results:
            print(f"  {label:10s} -> {path}")
    finally:
        c.close()


if __name__ == "__main__":
    main()
