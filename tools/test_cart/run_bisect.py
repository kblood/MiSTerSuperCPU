#!/usr/bin/env python3
"""Run the 4 draw_v* bisect variants through CRT wrap + deploy + screenshot."""
import hashlib
import os
import subprocess
import sys
import time

import paramiko

HOST = '192.168.50.130'
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
CRT_REMOTE = '/media/usb0/games/C64/bench.crt'
MGL = '/media/fat/_Test/bench_crt.mgl'


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=15)
    return c


def deploy_and_shot(c, name):
    crt_local = os.path.join(OUT, name + '.crt')
    s = c.open_sftp()
    s.put(crt_local, CRT_REMOTE)
    mgl_text = (
        '<mistergamedescription>\n'
        '<rbf>_Test/C64</rbf>\n'
        f'<file delay="3" type="f" index="1" path="{CRT_REMOTE}"/>\n'
        '</mistergamedescription>\n'
    )
    with s.open(MGL, 'w') as f:
        f.write(mgl_text)
    s.close()
    c.exec_command(f'echo "load_core {MGL}" > /dev/MiSTer_cmd')
    time.sleep(8)
    c.exec_command('rm -f /media/fat/screenshots/C64/*.png; '
                   'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    _, o, _ = c.exec_command('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rem = o.read().decode().strip()
    if not rem:
        return None, None
    s2 = c.open_sftp()
    local = os.path.join(OUT, name + '_shot.png')
    s2.get(rem, local); s2.close()
    h = hashlib.md5(open(local, 'rb').read()).hexdigest()[:8]
    return local, h


def main():
    variants = ['draw_v1_just_pass', 'draw_v2_first_two',
                'draw_v3_pass_last', 'draw_v4_pass_short']
    for v in variants:
        crt = os.path.join(OUT, v + '.crt')
        if not os.path.exists(crt):
            subprocess.run([sys.executable,
                            os.path.join(HERE, 'prg_to_crt.py'),
                            os.path.join(OUT, v + '.prg'),
                            '-n', v[:32]], check=True)
    c = ssh()
    print(f"CORENAME={c.exec_command('cat /tmp/CORENAME 2>/dev/null')[1].read().decode().strip()!r}")
    results = []
    for v in variants:
        print(f'=== {v} ===')
        path, h = deploy_and_shot(c, v)
        print(f'  shot={path} md5={h}')
        results.append((v, h))
    c.close()
    print()
    print('SUMMARY:')
    for v, h in results:
        print(f'  {v}: md5={h}')


if __name__ == '__main__':
    main()
