#!/usr/bin/env python3
"""Run test_pbr20_to_bank0 PRG on hardware. Result via border color."""
import os, time, paramiko, base64

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'test_pbr20_to_bank0.prg')
PRG_REMOTE = '/tmp/test_pbr20.prg'
MGL_REMOTE = '/tmp/test_pbr20.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_long_store_run')


def run(c, cmd, t=15):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def upload_prg(c):
    with open(PRG_LOCAL, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    run(c, 'rm -f {0}.b64 {0}'.format(PRG_REMOTE))
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, PRG_REMOTE))
    run(c, 'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(PRG_REMOTE))
    return run(c, 'wc -c < ' + PRG_REMOTE).strip()


def write_mgl(c):
    mgl_content = (
        '<mistergamedescription>\n'
        '  <rbf>_Test/C64</rbf>\n'
        '  <file delay="6" type="f" index="1" path="' + PRG_REMOTE + '"/>\n'
        '</mistergamedescription>\n'
    )
    run(c, 'rm -f ' + MGL_REMOTE)
    for line in mgl_content.split('\n'):
        if line.strip():
            run(c, "echo '" + line + "' >> " + MGL_REMOTE)


def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not rp:
        return None
    sftp = c.open_sftp()
    lp = os.path.join(OUT, name + '.png')
    sftp.get(rp, lp)
    sftp.close()
    return lp


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    sz = upload_prg(c)
    print('PRG uploaded, size=' + sz)
    write_mgl(c)
    print('MGL written')
    print(run(c, 'cat ' + MGL_REMOTE))

    # cfg byte 10 = 0x0c (overlay+scpu)
    run(c, "printf '\\x0c' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")

    print('reloading core...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('loading test MGL...')
    run(c, 'echo load_core ' + MGL_REMOTE + ' > /dev/MiSTer_cmd')
    time.sleep(20)

    p = shot(c, 'pbr20_test')
    print('screenshot -> {}'.format(os.path.basename(p) if p else 'NONE'))
    c.close()


if __name__ == '__main__':
    main()
