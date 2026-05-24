#!/usr/bin/env python3
"""Test the lorenz_autoload PRG: load disk + autoload PRG via single MGL,
verify Lorenz tests start without any keyboard input.

MGL format:
  <file index="0" type="s"> mounts the .d64 in drive 8
  <file index="1" type="f"> triggers PRG load+autostart (start_strk in
                            c64.sv:1036)
"""
import os
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "test_lorenz_autoload")
os.makedirs(OUT_DIR, exist_ok=True)


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS,
              timeout=10, look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(15)
    return c


def run(c, cmd, timeout=20):
    _, o, _ = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors="replace")


def screenshot(c, name):
    run(c, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2.5)
    out = run(c, "ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    remote = out.strip()
    if not remote:
        return None
    local = os.path.join(OUT_DIR, name)
    sftp = c.open_sftp()
    sftp.get(remote, local)
    sftp.close()
    print(f"  shot -> {name}")
    return local


def main():
    c = ssh()

    # Upload PRG
    prg_local = os.path.join(os.path.dirname(__file__),
                             "test_cart", "out", "lorenz_autoload.prg")
    prg_remote = "/media/fat/games/C64/lorenz_autoload.prg"
    sftp = c.open_sftp()
    sftp.put(prg_local, prg_remote)
    sftp.close()
    print(f"uploaded {prg_remote} ({os.path.getsize(prg_local)} bytes)")

    # Write MGL: disk + PRG (PRG triggers auto-RUN)
    mgl = ("<mistergamedescription>\n"
           "<rbf>_Test/C64</rbf>\n"
           '<file delay="2" type="s" index="0" '
           'path="/media/fat/games/C64/lorenz_disk1.d64"/>\n'
           '<file delay="8" type="f" index="1" '
           f'path="{prg_remote}"/>\n'
           "</mistergamedescription>\n")
    sftp = c.open_sftp()
    with sftp.open("/tmp/lorenz_auto.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    print(f"wrote MGL:\n{mgl}")

    # Confirm SCPU mode is enabled in cfg (we want to test the full system)
    cfg_val = 0x0c  # scpu mode
    run(c, "printf '\\x{:02x}' | dd of=/media/fat/config/C64.cfg "
          "bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(cfg_val))
    print(f"cfg byte 10 set to 0x{cfg_val:02x} (scpu mode)")

    # Load the MGL
    print("\nLoading MGL...")
    run(c, "echo load_core /tmp/lorenz_auto.mgl > /dev/MiSTer_cmd")
    time.sleep(15)
    run(c, "stty -F /dev/ttyS1 115200 raw -echo")

    # Series of screenshots; cumulative timestamps for filename clarity.
    intervals = [(5, "005s"), (10, "015s"), (15, "030s"),
                 (30, "060s"), (30, "090s"), (30, "120s")]
    screenshot(c, "t000s.png")
    print(f"  t=0s UART: {run(c, 'timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc \"[:print:]\\n\" | tail -1').strip()[:120]}")
    t_total = 0
    for dt, name in intervals:
        time.sleep(dt)
        t_total += dt
        screenshot(c, f"t{name}.png")
        uart = run(c, "timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -1")
        print(f"  t={t_total}s UART: {uart.strip()[:120]}")

    print(f"\nOutputs in {OUT_DIR}")
    c.close()


if __name__ == "__main__":
    main()
