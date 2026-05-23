#!/usr/bin/env python3
"""Upload a CRT to MiSTer and launch it via MGL + core reload.

Usage: python load_crt.py <local.crt> [--wait SECS]

MGL with <file type="f" index="1" path="..."> triggers cart load + reset.
Auto-boot CBM80 magic in the CRT then executes the embedded payload.
"""
import argparse
import sys
import time

import paramiko

HOST = "192.168.50.130"
REMOTE_CRT = "/media/usb0/games/C64/bench.crt"
REMOTE_MGL = "/media/fat/_Test/bench_crt.mgl"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('crt', help='local CRT file')
    ap.add_argument('--wait', type=float, default=5.0,
                    help='seconds to wait after load_core for boot')
    args = ap.parse_args()

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=10)

    stdin, stdout, _ = c.exec_command("cat /tmp/CORENAME 2>/dev/null")
    corename = stdout.read().decode().strip()
    if corename and corename not in ('C64', ''):
        print(f"ABORT: MiSTer is on core '{corename}' (not C64).")
        c.close()
        sys.exit(2)

    sftp = c.open_sftp()
    print(f"Uploading {args.crt} -> {REMOTE_CRT}")
    sftp.put(args.crt, REMOTE_CRT)

    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           f'<file delay="3" type="f" index="1" path="{REMOTE_CRT}"/>\n'
           '</mistergamedescription>\n')
    with sftp.open(REMOTE_MGL, 'w') as f:
        f.write(mgl)
    sftp.close()

    print(f"Loading via MGL ({REMOTE_MGL})")
    c.exec_command(f'echo "load_core {REMOTE_MGL}" > /dev/MiSTer_cmd')
    time.sleep(args.wait)
    print("Done.")
    c.close()


if __name__ == '__main__':
    main()
