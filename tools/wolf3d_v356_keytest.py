"""v356 follow-up — after SPACE+SPACE put Wolf3D in gray-screen state,
try every plausible key to see if the screen changes hash. If the gray
screen is a hidden 'press X to continue' state, one of these keys will
unstick it. If hash stays identical across all keys, the screen is
genuinely stuck (likely bitmap-mirror issue).

Assumes Wolf3D is already loaded + at the gray-screen state from the
previous v356 run. If not, re-deploy + run wolf3d_v356_test.py first.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v356_keytest')

KEYS = [
    'return',       # enter/select
    'y',            # yes
    'n',            # no
    'space',        # next
    'esc',          # escape
    'f1',           # function key (sometimes "press F1 to start")
    'up', 'down', 'left', 'right',  # menu navigation
    '1',            # episode 1
]


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

    baseline = shot(c, 'baseline')
    print('baseline: %s' % baseline)

    for k in KEYS:
        print('key=%s ...' % k)
        run(c, 'python3 /tmp/mtype.py %s 2>&1' % k, t=15)
        time.sleep(8)
        h = shot(c, 'after_' + k)
        marker = 'CHANGED!' if h != baseline else 'same'
        print('  after %s: %s  (%s)' % (k, h, marker))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
