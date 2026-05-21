#!/usr/bin/env python3
"""Run test_long_store_only.prg as the SOLE MGL <file> (autorun should work).

PASS = green border. FAIL = red border. Light blue = didn't run.
"""
import os, time, paramiko, base64
from collections import Counter
import re

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'test_long_store_only.prg')
PRG_REMOTE = '/tmp/test_long_store_only.prg'
MGL_REMOTE = '/tmp/test_long_store_only.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_long_store_only_run')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def upload(c):
    with open(PRG_LOCAL, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    run(c, 'rm -f {0}.b64 {0}'.format(PRG_REMOTE))
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, PRG_REMOTE))
    run(c, 'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(PRG_REMOTE))


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    upload(c)

    # SOLE PRG file - should autorun
    mgl = (
        '<mistergamedescription>\n'
        '  <rbf>_Test/C64</rbf>\n'
        '  <file delay="3" type="f" index="1" path="' + PRG_REMOTE + '"/>\n'
        '</mistergamedescription>\n'
    )
    run(c, 'rm -f ' + MGL_REMOTE)
    for line in mgl.split('\n'):
        if line.strip():
            run(c, "echo '" + line + "' >> " + MGL_REMOTE)

    # cfg byte 10 = 0x84 (SCPU + UART)
    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")

    print('reload core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('load MGL ...')
    run(c, 'echo load_core ' + MGL_REMOTE + ' > /dev/MiSTer_cmd')
    time.sleep(15)

    print('5s UART capture ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1', t=10)
    with open(os.path.join(OUT, 'uart_5s.txt'), 'w', errors='replace') as f:
        f.write(out)

    g_re = re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
    g_vals = g_re.findall(out)
    print('Total samples: {}'.format(len(g_vals)))
    if g_vals:
        last = g_vals[-1]
        print('  $00:$6C00 = ${}'.format(last[0]))
        print('  $2A:$6C00 = ${}  <<<<<'.format(last[1]))
        c44 = Counter(g[1] for g in g_vals)
        print('  $2A:$6C00 histogram: ' +
              ', '.join('${}={}'.format(v.upper(), n) for v,n in c44.most_common(5)))

    # Screenshot
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'border.png'))
        sftp.close()
        print('saved border.png')
    c.close()


if __name__ == '__main__':
    main()
