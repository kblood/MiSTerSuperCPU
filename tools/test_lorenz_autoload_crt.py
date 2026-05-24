#!/usr/bin/env python3
"""Test the lorenz_autoload CRT: self-contained boot to LOAD"*",8,1 + RUN.

Uses MGL with disk + CRT. The CRT bootstrap (prg_to_crt.py) copies our
ML loader to $C000, JMPs in. The ML configures KERNAL/CIA2, pokes a
BASIC LOAD program to $0801, pre-fills kbd buffer with "RUN\\r", and
JMPs to BASIC warm start. BASIC drains the buffer, RUNs the LOAD line,
which loads the disk's first file and chains.
"""
import os
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "test_lorenz_autoload_crt")
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

    crt_local = os.path.join(os.path.dirname(__file__),
                             "test_cart", "out", "lorenz_autoload.crt")
    crt_remote = "/media/fat/games/C64/lorenz_autoload.crt"
    sftp = c.open_sftp()
    sftp.put(crt_local, crt_remote)
    sftp.close()
    print(f"uploaded {crt_remote} ({os.path.getsize(crt_local)} bytes)")

    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" '
           'path="/media/fat/games/C64/lorenz_disk1.d64"/>\n'
           f'<file delay="8" type="f" index="1" path="{crt_remote}"/>\n'
           '</mistergamedescription>\n')
    sftp = c.open_sftp()
    with sftp.open("/tmp/lorenz_auto_crt.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    print(f"wrote MGL:\n{mgl}")

    # SCPU mode
    run(c, "printf '\\x0c' | dd of=/media/fat/config/C64.cfg "
          "bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    print("cfg byte 10 = 0x0c (scpu)")

    print("\nLoading MGL...")
    run(c, "echo load_core /tmp/lorenz_auto_crt.mgl > /dev/MiSTer_cmd")
    time.sleep(15)
    run(c, "stty -F /dev/ttyS1 115200 raw -echo")

    screenshot(c, "t000s.png")
    print(f"  t=0s UART: {run(c, 'timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc \"[:print:]\\n\" | tail -1').strip()[:120]}")

    for dt, name in [(5, "005s"), (10, "015s"), (15, "030s"),
                     (30, "060s"), (30, "090s")]:
        time.sleep(dt)
        screenshot(c, f"t{name}.png")
        uart = run(c, "timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -1")
        print(f"  t={name} UART: {uart.strip()[:120]}")

    print(f"\nOutputs in {OUT_DIR}")
    c.close()


if __name__ == "__main__":
    main()
