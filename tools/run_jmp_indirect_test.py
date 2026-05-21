#!/usr/bin/env python3
"""Run cpu_modes_test2.prg on MiSTer hardware in both T65 and SCPU=on modes,
read screen byte at $040D ($0E vs $5F), and report divergence.

T65 (NMOS wrap): JMP ($20FF) reads hi from $2000 (=$C3) -> $C300 -> writes $0E.
P65C816 (CMOS): JMP ($20FF) reads hi from $2100 (=$C4) -> $C400 -> writes $5F.
If divergent, NMOS-page-wrap is missing in P65C816 emu mode and is the DL root cause.
"""
import paramiko
import time
import sys

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

PRG = "tools/cpu_modes_test2.prg"
CFG = "/media/fat/config/C64.cfg"
RBF = "/media/fat/_Test/C64.rbf"


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, timeout=10):
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    return out, err


def set_scpu(c, on: bool):
    """Toggle status[82] via cfg byte 10 (offset 0x0a) bit 2."""
    out, _ = run(c, f"od -An -tx1 -N16 {CFG}")
    cfg_bytes = [int(b, 16) for b in out.split()]
    while len(cfg_bytes) < 16:
        cfg_bytes.append(0)
    if on:
        cfg_bytes[10] |= 0x04
    else:
        cfg_bytes[10] &= ~0x04
    hex_str = "".join(f"{b:02x}" for b in cfg_bytes)
    run(c, f"printf '{hex_str}' | xxd -r -p > /tmp/cfg.bin && dd if=/tmp/cfg.bin of={CFG} bs=1 count=16 conv=notrunc 2>/dev/null")
    print(f"  cfg byte 10 set to 0x{cfg_bytes[10]:02x} (SCPU={'on' if on else 'off'})")


def reload_core(c):
    run(c, f"echo load_core {RBF} > /dev/MiSTer_cmd")
    time.sleep(8)


def screenshot(c, local_path):
    """Trigger /dev/MiSTer_cmd screenshot, scp it back."""
    run(c, "ls /media/fat/screenshots/C64/ -t 2>/dev/null | head -3 > /tmp/before.txt")
    run(c, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    run(c, "ls /media/fat/screenshots/C64/ -t 2>/dev/null | head -3 > /tmp/after.txt")
    out, _ = run(c, "ls /media/fat/screenshots/C64/ -t | head -1")
    fname = out.strip()
    if not fname:
        return None
    sftp = c.open_sftp()
    sftp.get(f"/media/fat/screenshots/C64/{fname}", local_path)
    sftp.close()
    return local_path


def upload_prg(c):
    sftp = c.open_sftp()
    sftp.put(PRG, "/tmp/cpu_modes_test2.prg")
    sftp.close()


def load_and_run(c):
    # mbc load_rom should auto-RUN BASIC stub which contains SYS 49152
    run(c, "/media/fat/Scripts/.mbc load_rom C64 /tmp/cpu_modes_test2.prg")
    time.sleep(4)


def read_screen_byte(c, addr=0x040D):
    """The C64 screen RAM lives in C64 bus at $0400. We can't read it directly
    via MiSTer_cmd, but we can decode the resulting screenshot by extracting
    one character from the top-left."""
    # Easier: just take screenshot, manually inspect later.
    return None


def cycle(c, label, scpu_on):
    print(f"=== {label} (SCPU={'on' if scpu_on else 'off'}) ===")
    set_scpu(c, scpu_on)
    print("  reloading core...")
    reload_core(c)
    print("  uploading prg...")
    upload_prg(c)
    print("  loading PRG (mbc load_rom auto-runs)...")
    load_and_run(c)
    out_png = f"tools/jmp_test_{label.lower()}.png"
    print(f"  screenshotting -> {out_png}")
    p = screenshot(c, out_png)
    if p:
        print(f"  saved {p}")
    else:
        print("  ! screenshot failed")
    return out_png


def main():
    c = ssh()
    try:
        # T65 first
        t65_png = cycle(c, "T65", scpu_on=False)
        time.sleep(2)
        # Then SCPU
        scpu_png = cycle(c, "SCPU", scpu_on=True)
        print("\nDONE. Compare row 0 col 13 of both PNGs.")
        print(f"  T65:  {t65_png}")
        print(f"  SCPU: {scpu_png}")
    finally:
        c.close()


if __name__ == "__main__":
    main()
