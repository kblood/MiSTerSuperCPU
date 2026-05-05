#!/usr/bin/env python3
"""Run doom_minlaunch.prg on hardware:
   1. cfg byte 10 = 0x84 (SCPU + UART)
   2. load_core C64.rbf, wait 8s
   3. MGL with doom.reu (delay 3) + doom_minlaunch.prg (delay 15, index=1, autorun)
   4. Capture screenshots at 30s/60s/120s/240s
"""
import os, time, paramiko, base64, hashlib

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'doom_minlaunch.prg')
PRG_REMOTE = '/tmp/doom_minlaunch.prg'
MGL_REMOTE = '/tmp/doom_min.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_minlaunch')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def upload(c, local, remote):
    with open(local, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    run(c, 'rm -f {0}.b64 {0}'.format(remote))
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, remote))
    run(c, 'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(remote))
    return run(c, 'wc -c < ' + remote).strip()


def write_mgl(c):
    mgl = (
        '<mistergamedescription>\n'
        '  <rbf>_Test/C64</rbf>\n'
        '  <file delay="3" type="f" index="1" path="/media/fat/games/C64/doom.reu"/>\n'
        '  <file delay="15" type="f" index="1" path="' + PRG_REMOTE + '"/>\n'
        '</mistergamedescription>\n'
    )
    run(c, 'rm -f ' + MGL_REMOTE)
    for line in mgl.split('\n'):
        if line.strip():
            run(c, "echo '" + line + "' >> " + MGL_REMOTE)


def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not rp:
        return None, None
    sftp = c.open_sftp()
    lp = os.path.join(OUT, name + '.png')
    sftp.get(rp, lp)
    sftp.close()
    with open(lp, 'rb') as f:
        m = hashlib.md5(f.read()).hexdigest()[:12]
    return lp, m


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    sz = upload(c, PRG_LOCAL, PRG_REMOTE)
    print('PRG uploaded: {} bytes'.format(sz))
    write_mgl(c)
    print(run(c, 'cat ' + MGL_REMOTE))

    # cfg byte 10: SCPU(0x04) + Debug UART(0x80) = 0x84
    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    print('cfg byte 10 = 0x84')

    print('reloading core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('loading doom_min MGL ...')
    run(c, 'echo load_core ' + MGL_REMOTE + ' > /dev/MiSTer_cmd')

    t0 = time.time()
    for stage in [30, 60, 120]:
        wait = stage - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        p, m = shot(c, 'minlaunch_{}s'.format(stage))
        print('  t={:3d}s  {}  md5={}'.format(stage, os.path.basename(p) if p else 'NO', m))

    # Capture UART for 5s
    print('capturing UART 5s ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1 | head -c 4000', t=12)
    uart_path = os.path.join(OUT, 'uart_120s.txt')
    with open(uart_path, 'w', errors='replace') as f:
        f.write(out)
    print('UART -> ' + uart_path)
    # Print last 5 lines
    lines = out.split('\n')
    for ln in lines[-6:]:
        print('  ' + ln[:200])

    c.close()


if __name__ == '__main__':
    main()
