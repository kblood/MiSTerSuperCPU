"""Doom menu may still be up. Select NEW GAME with RETURN, then walk
through episode/skill selection.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_newgame')


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


def keypress(c, *keys):
    args = ' '.join(keys)
    run(c, 'python3 /tmp/mtype.py %s 2>&1' % args, t=15)


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    h = shot(c, 'pre')
    print('pre: %s' % h)

    # If menu disappeared (auto-close), bring it back with CTRL
    print('Tap CTRL to ensure menu open ...')
    keypress(c, 'ctrl'); time.sleep(2)
    h1 = shot(c, 'after_ctrl1'); print('  %s' % h1)

    # Try RETURN to select NEW GAME (cursor on top by default)
    keypress(c, 'return'); time.sleep(3)
    h2 = shot(c, 'after_return1'); print('  after return: %s' % h2)
    time.sleep(5)
    h3 = shot(c, 'after_return1_5s'); print('  +5s: %s' % h3)

    # Try RETURN again (should select episode 1)
    keypress(c, 'return'); time.sleep(3)
    h4 = shot(c, 'after_return2'); print('  after return2: %s' % h4)
    time.sleep(5)
    h5 = shot(c, 'after_return2_5s'); print('  +5s: %s' % h5)

    # Try RETURN for skill
    keypress(c, 'return'); time.sleep(3)
    h6 = shot(c, 'after_return3'); print('  after return3: %s' % h6)
    time.sleep(15)
    h7 = shot(c, 'after_return3_15s'); print('  +15s: %s' % h7)

    # Long wait for level load
    print('\n60s wait for level ...')
    time.sleep(60)
    h8 = shot(c, 'level_t60'); print('  level_t60: %s' % h8)
    time.sleep(60)
    h9 = shot(c, 'level_t120'); print('  level_t120: %s' % h9)

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
