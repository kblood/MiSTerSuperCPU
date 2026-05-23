#!/usr/bin/env python3
"""Deploy pass_draw_only.crt + screenshot."""
import hashlib
import os
import sys
import time
import paramiko

HOST = '192.168.50.130'
CRT_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'out', 'pass_draw_only.crt')
CRT_REMOTE = '/media/usb0/games/C64/bench.crt'
MGL = '/media/fat/_Test/bench_crt.mgl'
OUT_PNG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'out', 'pass_draw_only_t8s.png')


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username='root', password='1', timeout=15)
    _, o, _ = c.exec_command('cat /tmp/CORENAME 2>/dev/null')
    cn = o.read().decode().strip()
    if cn and cn not in ('C64', 'MENU', ''):
        print(f'ABORT cn={cn!r}'); sys.exit(2)
    print(f'CORENAME={cn!r}')

    s = c.open_sftp()
    print(f'upload {CRT_LOCAL}')
    s.put(CRT_LOCAL, CRT_REMOTE)
    mgl_text = (
        '<mistergamedescription>\n'
        '<rbf>_Test/C64</rbf>\n'
        f'<file delay="3" type="f" index="1" path="{CRT_REMOTE}"/>\n'
        '</mistergamedescription>\n'
    )
    with s.open(MGL, 'w') as f:
        f.write(mgl_text)
    s.close()

    print('load_core...')
    c.exec_command(f'echo "load_core {MGL}" > /dev/MiSTer_cmd')
    time.sleep(8)

    print('screenshot...')
    c.exec_command('rm -f /media/fat/screenshots/C64/*.png; '
                   'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    _, o, _ = c.exec_command('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rem = o.read().decode().strip()
    print(f'remote: {rem!r}')
    if rem:
        s2 = c.open_sftp()
        s2.get(rem, OUT_PNG); s2.close()
        h = hashlib.md5(open(OUT_PNG, 'rb').read()).hexdigest()[:8]
        print(f'saved {OUT_PNG} md5={h} size={os.path.getsize(OUT_PNG)}')
    c.close()


if __name__ == '__main__':
    main()
