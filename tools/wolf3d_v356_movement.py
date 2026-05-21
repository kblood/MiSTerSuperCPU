"""Test in-level movement on Wolf3D Level 1. If MiSTer state preserved,
inject arrow + WASD + ctrl + space and verify player moves (hash
changes per direction press, sustained motion).
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_movement')


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


def keypress(c, key):
    run(c, 'python3 /tmp/mtype.py %s 2>&1' % key, t=15)


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    h = shot(c, 'baseline')
    print('baseline: %s' % h)

    # Probe movement-style keys. Wolf3D PC: arrows + ctrl=fire + space=use
    # + alt=strafe. C64 ports may vary; try all.
    for k in ['up', 'down', 'left', 'right', 'w', 'a', 's', 'd', 'space', 'return']:
        keypress(c, k); time.sleep(2)
        h2 = shot(c, 'after_%s' % k)
        print('  after %s: %s' % (k, h2))

    # Repeated up to walk forward several steps
    print('\nRepeated UP (walk forward) x5 ...')
    for i in range(5):
        keypress(c, 'up'); time.sleep(2)
        h3 = shot(c, 'walk_%d' % (i+1))
        print('  walk_%d: %s' % (i+1, h3))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
