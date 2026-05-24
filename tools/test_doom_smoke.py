#!/usr/bin/env python3
"""Doom smoke test on v8 passthrough.

Just loads doom.reu + doom_loader.prg via MGL and screenshots at 30s
and 120s. Confirms Doom still attract-loops on v8.
"""
import os
import time
import paramiko

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "test_doom_smoke")
os.makedirs(OUT, exist_ok=True)


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.50.130", username="root", password="1", timeout=10)

    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           '<file delay="3" type="f" index="1" path="/media/fat/games/C64/doom.reu"/>\n'
           '<file delay="15" type="f" index="1" path="/media/fat/games/C64/doom_loader.prg"/>\n'
           '</mistergamedescription>\n')
    s = c.open_sftp()
    with s.open("/tmp/doom_smoke.mgl", "w") as f:
        f.write(mgl)
    s.close()

    # Set cfg to SCPU mode
    _, o, _ = c.exec_command(
        "printf '\\x0c' | dd of=/media/fat/config/C64.cfg bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    o.read()

    print("Loading Doom MGL...")
    c.exec_command("echo load_core /tmp/doom_smoke.mgl > /dev/MiSTer_cmd")
    time.sleep(25)  # delay=3+15 + core load = ~25s
    c.exec_command("stty -F /dev/ttyS1 115200 raw -echo")

    for t, name in [(0, "t000s"), (30, "t030s"), (60, "t060s"),
                    (120, "t120s")]:
        if t > 0:
            time.sleep(t - {0: 0, 30: 0, 60: 30, 120: 60}[t])
        c.exec_command("echo screenshot > /dev/MiSTer_cmd")
        time.sleep(2.5)
        _, o, _ = c.exec_command("ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
        remote = o.read().decode().strip()
        if remote:
            local = os.path.join(OUT, f"{name}.png")
            s = c.open_sftp(); s.get(remote, local); s.close()
            print(f"  shot {name}.png")
        _, o, _ = c.exec_command("timeout 1 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n' | tail -1")
        print(f"    UART: {o.read().decode().strip()[:120]}")

    c.close()
    print(f"\nOutputs in {OUT}")


if __name__ == "__main__":
    main()
