"""Doom v356 in-game input probe — corrected sequencing.

Fix vs probe.py: wait long enough for Doom to reach attract+menu
overlay BEFORE doing menu nav. Cold launch takes ~5 min wall.

Sequence:
  1. Load doom_autolaunch.mgl (cold)
  2. Poll screen every 30s for up to 8 min; detect "menu/attract"
     state by screenshot hash stability + visual eye-check
  3. Run canonical 4x RETURN-5s recipe
  4. Wait 120s for level load -> 3D gameplay
  5. Probe in-game inputs (1.5s hold each, screenshot before/after)
"""
import paramiko, time, os, hashlib, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.dirname(os.path.abspath(__file__))
MHOLD = os.path.join(os.path.dirname(OUT), 'mhold.py')


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
    s = c.open_sftp(); s.put(MHOLD, '/tmp/mhold.py'); s.close()

    print('=== cold load doom_autolaunch.mgl ===')
    cmd(c, 'echo load_core _Test/doom_autolaunch.mgl > /dev/MiSTer_cmd')

    # Poll up to 7 min for Doom to reach attract/menu
    print('=== polling for Doom to reach attract loop ===')
    last_h = None
    stable_runs = 0
    settled_at = None
    for t in range(30, 7 * 60 + 1, 30):
        time.sleep(30)
        h = shot(c, f'poll_t{t:03d}')
        marker = ''
        if h == last_h:
            stable_runs += 1
            marker = f' STABLE x{stable_runs}'
        else:
            stable_runs = 0
        print(f'  poll_t{t} {h}{marker}')
        last_h = h

    print('=== treating final shot as attract baseline; starting nav ===')
    h = shot(c, '20_pre_nav'); print('20_pre_nav', h)

    # Canonical menu nav
    waits = [3, 5, 10]
    for i, w in enumerate(waits):
        print(f'  ret #{i+1} (5s hold)')
        cmd(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
        time.sleep(w)
        h = shot(c, f'21_after_ret{i+1}'); print(f'  21_after_ret{i+1} {h}')

    print('  ret #4 (start level)')
    cmd(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
    h = shot(c, '22_after_final_ret'); print('22_after_final_ret', h)

    print('=== waiting 150s for JIT level build ===')
    for t in (30, 60, 90, 120, 150):
        time.sleep(30)
        h = shot(c, f'23_load_t{t:03d}'); print(f'  23_load_t{t} {h}')

    h = shot(c, '30_ingame'); print('30_ingame', h)

    keys = [
        ('arrow_up', 'up'),
        ('arrow_down', 'down'),
        ('arrow_left', 'left'),
        ('arrow_right', 'right'),
        ('rctrl', 'rctrl'),
        ('lctrl', 'lctrl'),
        ('space', 'space'),
        ('lalt', 'lalt'),
        ('ralt', 'ralt'),
        ('w', 'w'),
        ('s', 's'),
        ('a', 'a'),
        ('d', 'd'),
        ('tab', 'tab'),
    ]

    print('=== in-game key probe (2s hold each) ===')
    for label, key in keys:
        print(f'  probe {label}')
        h0 = shot(c, f'40_{label}_pre')
        cmd(c, f'python3 /tmp/mhold.py {key} 2 2>&1', t=20)
        time.sleep(3.0)
        h1 = shot(c, f'40_{label}_post')
        marker = ' MOVED' if h0 != h1 else '   ==='
        print(f'    pre={h0} post={h1}{marker}')

    c.close()


if __name__ == '__main__':
    sys.exit(main() or 0)
