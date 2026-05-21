"""Doom menu is up but RETURN doesn't select. Try arrow nav + various
select keys.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_menu_keys')


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

    pre = shot(c, 'pre')
    print('pre: %s' % pre)

    # Ensure menu open with CTRL
    keypress(c, 'ctrl'); time.sleep(2)
    h = shot(c, 'after_ctrl'); print('after ctrl: %s' % h)

    # Try down arrows to verify cursor moves
    for i, k in enumerate(['down', 'down', 'up']):
        keypress(c, k); time.sleep(2)
        h = shot(c, '%d_%s' % (i, k))
        print('%d %s: %s' % (i, k, h))

    # Try various select keys
    for sel in ['space', 'return', 'y', 'n', '1', 'ctrl', 'alt', 'f5']:
        keypress(c, sel); time.sleep(3)
        h = shot(c, 'sel_%s' % sel)
        print('sel %s: %s' % (sel, h))
        time.sleep(3)
        h2 = shot(c, 'sel_%s_after' % sel)
        if h2 != h:
            print('  STATE ADVANCED %s -> %s' % (h, h2))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
