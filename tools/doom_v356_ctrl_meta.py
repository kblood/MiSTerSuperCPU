"""Test if Doom responds to CTRL/ALT/META/SHIFT (Doom PC fire/run/use
keys, plus C64 Commodore key). Doom is currently cycling through
attract — title + credits + order form. Most attract screens skip
ordinary keys.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_ctrl_meta')


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

    # Upload updated mtype.py with ctrl/alt/meta/shift
    sftp = c.open_sftp()
    sftp.put(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mtype.py'), '/tmp/mtype.py')
    sftp.close()

    base = shot(c, 'baseline')
    print('baseline: %s' % base)

    # Test each key over 30s window — Doom transitions every ~140s, so
    # in 30s we're either at title, credits, or order.
    keys = ['ctrl', 'lctrl', 'rctrl', 'alt', 'lalt', 'ralt',
            'shift', 'super', 'meta', 'pgup', 'pgdn', 'home', 'end',
            'tab', 'backspace', 'f1', 'f7']
    for k in keys:
        keypress(c, k); time.sleep(3)
        h = shot(c, 'k_%s' % k)
        chg = ' CHANGED' if h != base else ''
        print('  after %s: %s%s' % (k, h, chg))
        base = h  # rolling baseline since Doom is cycling anyway

    # Try arrow + ctrl combo (Doom PC walk+fire)
    print('\nDoom PC combos ...')
    for combo in [('up ctrl', 'walk_fire'), ('left ctrl', 'turn_left_fire'),
                  ('right ctrl', 'turn_right_fire')]:
        keys_arg, label = combo
        run(c, 'python3 /tmp/mtype.py %s' % keys_arg, t=15); time.sleep(3)
        h = shot(c, label); print('  %s: %s' % (label, h))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
