#!/usr/bin/env python3
"""Doom long-settle (240s) regression on v274 — both T65 and SCPU.

Reproduces tools/v272_doom_full.py but writes to tools/doom_v274/ so we can
compare against v272 evidence directly. Each mode: cfg-mutate byte10, reload
core, MGL-load doom.reu+doom_loader.prg, snapshot at 60/120/180/240s.

Output:  tools/doom_v274/doom_<mode>_<seconds>s.png
"""
import os, time, paramiko, hashlib

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
MGL = '/media/fat/_Test/doom_full_abs.mgl'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\doom_v274'


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
        return None, None
    sftp = c.open_sftp()
    lp = os.path.join(OUT, name + '.png')
    sftp.get(rp, lp)
    sftp.close()
    with open(lp, 'rb') as f:
        m = hashlib.md5(f.read()).hexdigest()[:12]
    return lp, m


def main():
    c = ssh()
    summary = []
    try:
        for mode, val in [('t65', 0x08), ('scpu', 0x0C)]:
            print('--- doom_v274 [{}] cfg=0x{:02x} ---'.format(mode, val))
            setcfg(c, val)
            run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
            time.sleep(8)
            run(c, 'echo load_core ' + MGL + ' > /dev/MiSTer_cmd')
            t0 = time.time()
            for stage in [60, 120, 180, 240]:
                wait = stage - (time.time() - t0)
                if wait > 0:
                    time.sleep(wait)
                p, m = shot(c, 'doom_{}_{}s'.format(mode, stage))
                print('   t={:3d}s  {}  md5={}'.format(stage, os.path.basename(p) if p else 'NO-SHOT', m))
                summary.append((mode, stage, m))
    finally:
        c.close()
    with open(os.path.join(OUT, '_summary.txt'), 'w') as f:
        for mode, stage, m in summary:
            f.write('{}  t={:3d}s  md5={}\n'.format(mode, stage, m))
    print('summary -> {}'.format(os.path.join(OUT, '_summary.txt')))


if __name__ == '__main__':
    main()
