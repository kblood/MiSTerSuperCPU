"""Sanity test: load C64 core, wait, type POKE 53281,2 + enter. Screenshot.
If background turns red, mtype works.
"""
import os, time, paramiko, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'


def run(c, cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace') + e.read().decode(errors='replace')


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    cn = run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    print('CORENAME=%r' % cn)

    sftp = c.open_sftp()
    sftp.put('tools/mtype.py', '/tmp/mtype.py')
    sftp.close()

    print('Loading C64 core fresh ...')
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % RBF)
    time.sleep(8)

    print('Type POKE53281,2<Enter> ...')
    out = run(c, "python3 /tmp/mtype.py 'POKE53281,2' enter", t=30)
    print('mtype output: ' + repr(out))
    time.sleep(2)

    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        local = 'tools/doom_full/sanity_mtype_poke.png'
        sftp.get(rp, local)
        sftp.close()
        print('Screenshot saved: ' + local)
    c.close()


if __name__ == '__main__':
    sys.exit(main())
