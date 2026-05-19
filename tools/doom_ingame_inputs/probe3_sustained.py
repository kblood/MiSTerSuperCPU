"""Sharper Doom in-game input test.

Assumes Doom is currently in 3D gameplay (left over from probe2.py).

For each key class, hold for 10 seconds and screenshot at t=0 / t=5 / t=10
to see if a sustained press produces obvious movement.

Then try joystick port 2 (USB gamepad spoof at VID/PID 0810/e501) for
4 axis directions + fire button.
"""
import paramiko, time, os, hashlib, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.dirname(os.path.abspath(__file__))
MHOLD = os.path.join(os.path.dirname(OUT), 'mhold.py')
JTYPE = os.path.join(os.path.dirname(OUT), 'jtype.py')


def cmd(c, s, t=30):
    _, o, e = c.exec_command(s, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def shot(c, label):
    cmd(c, 'rm -f /media/fat/screenshots/C64/*.png; echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    out, _ = cmd(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rp = out.strip()
    if rp:
        s = c.open_sftp(); s.get(rp, os.path.join(OUT, label + '.png')); s.close()
        h = hashlib.sha256(open(os.path.join(OUT, label + '.png'), 'rb').read()).hexdigest()[:10]
        return h
    return 'NONE'


def main():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    s = c.open_sftp(); s.put(MHOLD, '/tmp/mhold.py')
    if os.path.exists(JTYPE):
        s.put(JTYPE, '/tmp/jtype.py')
    s.close()

    h = shot(c, '50_start'); print('start:', h)
    if h == 'NONE':
        print('no screenshot — aborting')
        return 1

    keys = ['up', 'down', 'left', 'right', 'space', 'rctrl', 'tab']

    for k in keys:
        print(f'=== sustained 10s hold: {k} ===')
        h0 = shot(c, f'51_{k}_t0')
        print(f'  t0 {h0}')
        # Run mhold.py for 10s; don't block waiting for completion until later
        ch = c.get_transport().open_session()
        ch.exec_command(f'python3 /tmp/mhold.py {k} 10 2>&1')
        time.sleep(4.0)
        h_mid = shot(c, f'51_{k}_t5')
        print(f'  t5  {h_mid}')
        time.sleep(7.0)
        h1 = shot(c, f'51_{k}_t10')
        print(f'  t10 {h1}')
        try:
            ch.recv(4096)
            ch.close()
        except Exception:
            pass
        if h_mid != h0 or h1 != h0:
            print(f'  {k}: STATE CHANGED')
        else:
            print(f'  {k}: no change')
        time.sleep(2.0)  # settle

    # Control: no key, see if screen still changes
    print('=== CONTROL: 10s no input ===')
    h0 = shot(c, '52_ctrl_t0')
    time.sleep(4.0)
    h_mid = shot(c, '52_ctrl_t5')
    time.sleep(7.0)
    h1 = shot(c, '52_ctrl_t10')
    print(f'  ctrl: t0={h0} t5={h_mid} t10={h1}')

    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
