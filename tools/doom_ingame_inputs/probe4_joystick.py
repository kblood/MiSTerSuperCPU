"""Doom in-game joystick test.

js0 = real "usb gamepad" at usb-1.5. To get my virtual joystick into
that slot, unbind usb-1.5 first, then create the virtual gamepad with
the same VID/PID, then bind back at the end.

Test sequence:
  1. Unbind usb-1.5 (real usb gamepad → js0 vanishes)
  2. Hold UP via jtype.py for 5s → screenshot
  3. Hold DOWN for 5s → screenshot
  4. Hold LEFT for 5s → screenshot
  5. Hold RIGHT for 5s → screenshot
  6. Hold FIRE for 1s → screenshot
  7. Re-bind usb-1.5 at the end
"""
import paramiko, time, os, hashlib, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.dirname(os.path.abspath(__file__))
JTYPE = os.path.join(os.path.dirname(OUT), 'jtype.py')

UNBIND = 'echo -n 1-1.5:1.0 > /sys/bus/usb/drivers/usbhid/unbind 2>&1; echo unbind-rc=$?'
REBIND = 'echo -n 1-1.5:1.0 > /sys/bus/usb/drivers/usbhid/bind 2>&1; echo bind-rc=$?'


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
        return hashlib.sha256(open(os.path.join(OUT, label + '.png'), 'rb').read()).hexdigest()[:10]
    return 'NONE'


def main():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    s = c.open_sftp(); s.put(JTYPE, '/tmp/jtype.py'); s.close()

    h = shot(c, '60_start'); print('start:', h)

    print('=== unbind real usb gamepad (usb-1.5) ===')
    out, _ = cmd(c, UNBIND); print(out.strip())
    time.sleep(2)
    out, _ = cmd(c, 'ls /dev/input/js* 2>/dev/null'); print('js slots after unbind:', out.strip())

    holds = [('up', 'up'), ('down', 'down'), ('left', 'left'), ('right', 'right')]

    for label, dir_ in holds:
        print(f'=== virtual gamepad: hold {label} 5s ===')
        h0 = shot(c, f'61_{label}_pre')
        # Use hold:DIR:5000 to push dir for 5s
        ch = c.get_transport().open_session()
        ch.exec_command(f'python3 /tmp/jtype.py hold:{dir_}:5000 2>&1')
        # jtype.py sleeps 6s for device creation, then holds 5s
        time.sleep(8.5)
        h_mid = shot(c, f'61_{label}_mid')
        time.sleep(3.5)
        h1 = shot(c, f'61_{label}_post')
        try:
            ch.recv(8192); ch.close()
        except Exception:
            pass
        marker = ' MOVED' if h0 != h1 or h_mid != h0 else '   ==='
        print(f'  pre={h0} mid={h_mid} post={h1}{marker}')
        time.sleep(2)

    print('=== virtual gamepad: tap FIRE ===')
    h0 = shot(c, '62_fire_pre')
    ch = c.get_transport().open_session()
    ch.exec_command('python3 /tmp/jtype.py hold:fire:1000 2>&1')
    time.sleep(8.5)
    h1 = shot(c, '62_fire_post')
    try:
        ch.recv(8192); ch.close()
    except Exception:
        pass
    print(f'  pre={h0} post={h1} {"MOVED" if h0 != h1 else "==="}')

    print('=== re-bind usb-1.5 ===')
    out, _ = cmd(c, REBIND); print(out.strip())
    time.sleep(2)
    out, _ = cmd(c, 'ls /dev/input/js* 2>/dev/null'); print('js slots after rebind:', out.strip())

    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
