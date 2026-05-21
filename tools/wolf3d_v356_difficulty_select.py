"""Wolf3D currently at difficulty select. Try various keys to commit and
proceed to level load.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_diff_sel')


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

    base = shot(c, 'pre')
    print('pre: %s' % base)

    # Try selecting difficulty via space, return, y, 1 in sequence
    for k in ['space', 'y', '1', '2', '3', 'return', 'space']:
        keypress(c, k); time.sleep(3)
        h = shot(c, 'after_%s' % k)
        print('  after %s: %s' % (k, h))

    # Long wait to see if level loads
    print('\nWaiting 120s for level/transition ...')
    for i in range(8):
        time.sleep(15)
        h = shot(c, 'wait_t%d' % ((i+1)*15))
        print('  wait_t%d: %s' % ((i+1)*15, h))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
