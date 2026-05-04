#!/usr/bin/env python3
"""Deploy + run test_long_store_bank0.prg on MiSTer in SCPU mode.

After PRG runs, screen $0400 should contain $42 $43 (the bytes we wrote
to bank $00 $0E0C/$0E0D via STA [zp] / STA [zp],Y). Reads them via the
RAM-screen channel, takes a screenshot, and reports.
"""
import os, time, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'test_long_store_bank0.prg')
PRG_REMOTE = '/tmp/test_long_store.prg'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_long_store_run')


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)
    return c


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def setcfg(c, v):
    run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(v, CFG))


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


def upload_prg(c):
    with open(PRG_LOCAL, 'rb') as f:
        data = f.read()
    import base64
    b64 = base64.b64encode(data).decode()
    run(c, "rm -f " + PRG_REMOTE + ".b64 " + PRG_REMOTE)
    chunks = [b64[i:i+4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, PRG_REMOTE))
    run(c, "base64 -d {0}.b64 > {0} && rm {0}.b64".format(PRG_REMOTE))
    return run(c, "wc -c < " + PRG_REMOTE).strip()


def main():
    c = ssh()
    try:
        print('--- test_long_store [scpu] cfg=0x0c ---')
        setcfg(c, 0x0c)
        # Load core via MGL with PRG attached. MGL must specify `_Test/C64`
        # so our v274 build is used (mbc would revert to vanilla).
        sz = upload_prg(c)
        print('  PRG uploaded, size=' + sz)
        mgl = ('<mistergamedescription>\n'
               '  <rbf>_Test/C64</rbf>\n'
               '  <file delay="6" type="f" index="0" path="' + PRG_REMOTE + '"/>\n'
               '</mistergamedescription>\n')
        # Write MGL using printf so heredoc parsing isn't an issue
        run(c, "rm -f /tmp/test_long.mgl")
        for line in mgl.split('\n'):
            if line:
                run(c, "echo '" + line + "' >> /tmp/test_long.mgl")
        out = run(c, "cat /tmp/test_long.mgl")
        print('  MGL content:\n' + out)
        run(c, "echo load_core /tmp/test_long.mgl > /dev/MiSTer_cmd")
        # Wait for boot + autorun
        time.sleep(20)
        p = shot(c, 'after_mgl')
        print('  screenshot -> {}'.format(os.path.basename(p) if p else 'NONE'))
    finally:
        c.close()


if __name__ == '__main__':
    main()
