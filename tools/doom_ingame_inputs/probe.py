"""Doom v356 in-game input probe.

Sequence:
  1. Load doom_autolaunch.mgl  (RBF + REU + launcher.prg, attract loop)
  2. Wait for attract/title overlay
  3. Run the canonical menu navigation recipe (4x RETURN holds 5s)
  4. Wait 120s for level load → 3D rendered E1M1
  5. For each candidate in-game key, hold 1s, screenshot before/after

The candidate keys cover the standard Doom keyboard map:
  arrow_up / arrow_down / arrow_left / arrow_right    (move/turn)
  rctrl / lctrl / ctrl                                (fire)
  space                                               (use/open)
  ralt / lalt                                         (strafe)
  return / enter                                      (menu select)
  w / a / s / d                                       (WASD alt)
  i / j / k / l                                       (IJKL alt)
  tab                                                 (map)
  esc                                                 (menu)

Hold time = 1.5s (enough for ~4-5 Doom frames at the observed 3 fps).
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


def hold(c, key, sec=1.5):
    """Hold one key for `sec` seconds via mhold.py."""
    return cmd(c, f'python3 /tmp/mhold.py {key} {sec} 2>&1', t=int(sec) + 20)[0]


def main():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    print('=== upload mhold.py ===')
    s = c.open_sftp(); s.put(MHOLD, '/tmp/mhold.py'); s.close()

    print('=== load doom_autolaunch.mgl ===')
    cmd(c, 'echo load_core _Test/doom_autolaunch.mgl > /dev/MiSTer_cmd')

    print('waiting 25s for boot + REU load + launcher autolaunch ...')
    time.sleep(25)
    h = shot(c, '00_after_load'); print('00_after_load', h)

    print('waiting 12s for attract loop / menu overlay ...')
    time.sleep(12)
    h = shot(c, '01_attract'); print('01_attract', h)

    print('=== menu nav: 4 RETURN holds (5s each) ===')
    waits = [3, 5, 10]
    for i, w in enumerate(waits):
        print(f'  ret #{i+1}')
        cmd(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
        time.sleep(w)
        h = shot(c, f'02_after_ret{i+1}'); print(f'  02_after_ret{i+1}', h)

    print('  final ret #4 -> start level load')
    cmd(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
    h = shot(c, '03_after_final_ret'); print('03_after_final_ret', h)

    print('=== waiting 120s for JIT level build ===')
    for t in (30, 60, 90, 120):
        time.sleep(30)
        h = shot(c, f'04_load_t{t}'); print(f'  04_load_t{t}', h)

    h = shot(c, '05_ingame'); print('05_ingame baseline', h)

    keys = [
        ('arrow_up', 'up'),
        ('arrow_down', 'down'),
        ('arrow_left', 'left'),
        ('arrow_right', 'right'),
        ('rctrl', 'rctrl'),
        ('lctrl', 'lctrl'),
        ('space', 'space'),
        ('ralt', 'ralt'),
        ('lalt', 'lalt'),
        ('return', 'return'),
        ('w', 'w'),
        ('a', 'a'),
        ('s', 's'),
        ('d', 'd'),
        ('i', 'i'),
        ('j', 'j'),
        ('k', 'k'),
        ('l', 'l'),
        ('tab', 'tab'),
        ('esc', 'esc'),
    ]

    print('=== in-game key probe (1.5s hold each) ===')
    for label, key in keys:
        print(f'  probe {label}')
        # Pre-shot for diff
        h0 = shot(c, f'10_{label}_pre')
        hold(c, key, 1.5)
        # Wait briefly for any render reaction (3 fps means render takes ~330ms)
        time.sleep(2.0)
        h1 = shot(c, f'10_{label}_post')
        marker = ' MOVED' if h0 != h1 else '   ==='
        print(f'    pre={h0} post={h1} {marker}')

    c.close()


if __name__ == '__main__':
    sys.exit(main() or 0)
