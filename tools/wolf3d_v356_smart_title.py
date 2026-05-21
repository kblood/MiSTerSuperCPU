"""Watch Wolf3D state, detect known title-screen hash 3a0b0f9f54, then
spam keys IMMEDIATELY. Uses current Wolf3D state (no redeploy).
Wolf3D attract cycle is ~6 min; title window in each cycle is ~60s.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_smart_title')

TITLE_HASH = '3a0b0f9f54'
HIGH_HASH = '28a41c2d81'   # high scores also a stable screen we can try


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

    print('Watching for title hash %s (max 12 minutes) ...' % TITLE_HASH)
    triggered_title = False
    triggered_high = False
    for i in range(72):  # 72 * 10s = 720s = 12 min
        time.sleep(10)
        h = shot(c, 'w_%03d' % (i*10))
        print('  t+%ds: %s' % (i*10, h))
        if h == TITLE_HASH and not triggered_title:
            triggered_title = True
            print('    *** TITLE SCREEN DETECTED — spamming keys ***')
            for k in ['return', 'space', 'esc', 'y', '1']:
                keypress(c, k); time.sleep(2)
                hk = shot(c, 'title_%s' % k)
                print('    after %s: %s' % (k, hk))
            # After spam, capture 3 more shots over 30s to see if state stuck
            for j in range(3):
                time.sleep(10)
                hp = shot(c, 'post_title_t%d' % (j*10))
                print('    post_t%d: %s' % (j*10, hp))
        elif h == HIGH_HASH and not triggered_high:
            triggered_high = True
            print('    *** HIGH SCORES DETECTED — trying ESC+SPACE ***')
            for k in ['esc', 'space']:
                keypress(c, k); time.sleep(2)
                hk = shot(c, 'high_%s' % k)
                print('    after %s: %s' % (k, hk))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
