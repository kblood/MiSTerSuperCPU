"""Run SCPU-native bitmap test PRG and capture screenshot.

If renders correctly (red border + light grey area), Tier-3 bank-$01
mirror is working — Doom black-screen is a Doom-specific bug elsewhere.
If black/garbled, Tier-3 mirror has a routing bug under native-mode
long-stores.
"""
import os, time, paramiko, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
PRG_LOCAL = 'tools/bitmap_render_test_scpu.prg'
MGL_LOCAL = 'tools/bitmap_render_test_scpu.mgl'


def run(c, cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace') + e.read().decode(errors='replace')


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    cn = run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    if cn and cn not in ('C64', 'MENU'):
        print('ABORT: CORENAME=%r' % cn)
        return 2
    print('CORENAME=%r' % cn)

    sftp = c.open_sftp()
    sftp.put(PRG_LOCAL, '/media/usb0/games/C64/bitmap_render_test_scpu.prg')
    sftp.put(MGL_LOCAL, '/media/fat/_Test/bitmap_render_test_scpu.mgl')
    sftp.put('tools/mtype.py', '/tmp/mtype.py')
    sftp.close()
    print('PRG + MGL uploaded.')

    print('load_core MGL ...')
    run(c, 'echo load_core /media/fat/_Test/bitmap_render_test_scpu.mgl > /dev/MiSTer_cmd')
    time.sleep(10)

    print('Type SYS2061<Enter> ...')
    run(c, "python3 /tmp/mtype.py 'SYS2061' enter", t=30)
    time.sleep(3)

    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        local = 'tools/doom_full/bitmap_render_test_scpu.png'
        sftp.get(rp, local)
        sftp.close()
        print('Screenshot saved: ' + local)
    c.close()


if __name__ == '__main__':
    sys.exit(main())
