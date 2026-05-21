"""Quick ESC + alternate-key probe against currently-loaded Wolf3D.
Each key gets 2 captures: one immediately, one 5s after, so we can
distinguish 'state changed permanently' from 'just demo frame at the
moment of capture'.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v356_esc')

KEYS = ['esc', 'f1', 'f10', 'tab', 'home', 'p', 'q', 'a', 's']


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def shot(c, label):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, label + '.png')); sftp.close()
    p = os.path.join(OUT, label + '.png')
    if os.path.exists(p):
        return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:10]
    return 'NONE'


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    print('Pre-baseline (current Wolf3D state):')
    b1 = shot(c, 'pre_a')
    time.sleep(5)
    b2 = shot(c, 'pre_b')
    print('  pre_a=%s pre_b=%s (changed=%s)' % (b1, b2, b1 != b2))

    for k in KEYS:
        print('\nkey=%s' % k)
        run(c, 'python3 /tmp/mtype.py %s 2>&1' % k, t=15)
        time.sleep(2)
        a = shot(c, '%s_imm' % k)
        time.sleep(8)
        b = shot(c, '%s_5s' % k)
        # If imm and 5s differ, demo still animating; if both stable and DIFFERENT from
        # pre baseline, key may have stuck in a new state.
        diff_animating = a != b
        diff_from_pre = (a != b1 and a != b2) and (b != b1 and b != b2)
        print('  imm=%s after_5s=%s  animating=%s out_of_pre=%s' % (
            a, b, diff_animating, diff_from_pre))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
