#!/usr/bin/env python3
"""Doom full-loader long-settle: snapshot at 60/120/180/240/300s.

Goal: see if loader transitions from $000788 loop to game code, and if so,
where. The 90s test showed PC stuck in $000788..$078E (loader code).
"""
import os, time, paramiko, re
from collections import Counter

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
MGL = '/media/fat/_Test/doom_full_abs.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full_long')
SETTLES = [60, 120, 180, 240, 300]


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def snap(c, label):
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1', t=10)
    pc_re = re.compile(r'PC:([0-9A-Fa-f]{6})')
    f_re = re.compile(r'F:([0-9A-Fa-f]{4})')
    pc_vals = pc_re.findall(out)
    f_vals = f_re.findall(out)
    pc_ctr = Counter(pc_vals)
    print('  [%s] %d samples, F[first..last]=%s..%s' % (
        label,
        len(pc_vals),
        f_vals[0] if f_vals else '?',
        f_vals[-1] if f_vals else '?'))
    for pc, cnt in pc_ctr.most_common(3):
        print('    $%s -> %d (%.0f%%)' % (pc.upper(), cnt, 100*cnt/max(1,len(pc_vals))))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    print('reload core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('load doom MGL ...')
    run(c, 'echo load_core ' + MGL + ' > /dev/MiSTer_cmd')

    last = 0
    for s in SETTLES:
        wait = s - last
        print('settle +%ds (total %ds) ...' % (wait, s))
        time.sleep(wait)
        last = s
        out = snap(c, '%ds' % s)
        with open(os.path.join(OUT, 'uart_%03ds.txt' % s), 'w', errors='replace') as f:
            f.write(out)
        # screenshot
        run(c, 'rm -f /media/fat/screenshots/C64/*.png')
        run(c, 'echo screenshot > /dev/MiSTer_cmd')
        time.sleep(2.5)
        rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
        if rp:
            sftp = c.open_sftp()
            sftp.get(rp, os.path.join(OUT, 'screen_%03ds.png' % s))
            sftp.close()

    c.close()


if __name__ == '__main__':
    main()
