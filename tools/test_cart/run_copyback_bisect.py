#!/usr/bin/env python3
"""Wrap each cbk_v*_*.prg as a CRT, deploy to MiSTer, screenshot.

Sequential. Each iteration ~12s wall (3s MGL delay + 8s settle + 1s shot).
"""
import hashlib
import os
import sys
import time

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prg_to_crt import make_boot_crt
import importlib
_MODULE = os.environ.get('BISECT_MODULE', 'gen_copyback_bisect')
_mod = importlib.import_module(_MODULE)
VARIANTS = _mod.VARIANTS
OUT_DIR = _mod.OUT_DIR

HOST = '192.168.50.130'
CRT_REMOTE = '/media/usb0/games/C64/bench.crt'
MGL = '/media/fat/_Test/bench_crt.mgl'


def deploy_one(client, name):
    prg_path = os.path.join(OUT_DIR, name + '.prg')
    crt_path = os.path.join(OUT_DIR, name + '.crt')
    png_path = os.path.join(OUT_DIR, name + '_t8s.png')

    with open(prg_path, 'rb') as f:
        prg = f.read()
    crt, info = make_boot_crt(prg, name=name.upper()[:16])
    with open(crt_path, 'wb') as f:
        f.write(crt)

    s = client.open_sftp()
    s.put(crt_path, CRT_REMOTE)
    mgl_text = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                f'<file delay="3" type="f" index="1" path="{CRT_REMOTE}"/>\n'
                '</mistergamedescription>\n')
    with s.open(MGL, 'w') as f:
        f.write(mgl_text)
    s.close()

    client.exec_command(f'echo "load_core {MGL}" > /dev/MiSTer_cmd')
    time.sleep(8)
    client.exec_command('rm -f /media/fat/screenshots/C64/*.png; '
                        'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    _, o, _ = client.exec_command(
        'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rem = o.read().decode().strip()
    if not rem:
        print(f"  {name}: NO SCREENSHOT")
        return

    s2 = client.open_sftp()
    s2.get(rem, png_path)
    s2.close()
    h = hashlib.md5(open(png_path, 'rb').read()).hexdigest()[:8]
    print(f"  {name}: md5={h} -> {png_path} "
          f"(entry=${info['entry']:04X}, pages={info['pages_copied']})")


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=15)
    try:
        # Ownership check
        _, o, _ = c.exec_command('cat /tmp/CORENAME 2>/dev/null')
        core = o.read().decode().strip()
        if core and core != 'C64':
            print(f"ABORT: /tmp/CORENAME={core!r}; other agent owns MiSTer")
            return
        for name, _ in VARIANTS:
            deploy_one(c, name)
    finally:
        c.close()


if __name__ == '__main__':
    main()
