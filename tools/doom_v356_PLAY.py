"""Doom v356: canonical recipe to launch + reach 3D gameplay.

REQUIRED: v356 RBF deployed, Doom REU+launcher already loaded so the
attract loop is showing the main menu overlay. Run on a host with
paramiko; mhold.py uploaded to /tmp on MiSTer.

THE KEY INSIGHT: HW Doom runs at ~3 fps internal. mtype.py's 40 ms
key holds get missed entirely. Use mhold.py to hold RETURN for 5 s
each press — Doom polls the keyboard matrix slowly enough that a
full-second hold is needed to register.

Recipe:
  1. Hold RETURN 5 s        — select NEW GAME → episode-select screen
  2. wait 3 s, hold RETURN 5 s — select Episode 1 → skill-select screen
  3. wait 5 s, hold RETURN 5 s — select default skill (HEY NOT TOO ROUGH)
  4. wait ~100 s            — JIT recompiler builds level + maps loaded
  5. game renders 3D level with HUD (HEALTH/AMMO/ARMOR/face)

NO joystick required. NO autofire. NO USB unbinding. Just keyboard
with long holds.
"""
import paramiko, time, os, hashlib, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_v356_play')


def run(c, cmd, t=30):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def shot(c, label):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png; echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        s = c.open_sftp(); s.get(rp, os.path.join(OUT, label + '.png')); s.close()
        return hashlib.sha256(open(os.path.join(OUT, label + '.png'), 'rb').read()).hexdigest()[:10]
    return 'NONE'


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    sftp = c.open_sftp()
    sftp.put(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mhold.py'),
             '/tmp/mhold.py')
    sftp.close()

    h = shot(c, '00_pre'); print('pre (attract+menu):', h)

    for i, wait in enumerate([3, 5, 10]):
        print('=== hold RETURN 5s #%d ===' % (i + 1))
        run(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
        h = shot(c, '%02d_after_ret' % (i + 1)); print('  immediate:', h)
        time.sleep(wait)
        h = shot(c, '%02d_after_ret_settled' % (i + 1)); print('  +%ds:' % wait, h)

    # Final RETURN to start the chosen skill
    print('=== final RETURN 5s (start game) ===')
    run(c, 'python3 /tmp/mhold.py return 5 2>&1', t=20)
    h = shot(c, '04_after_final'); print('  immediate:', h)

    print('waiting for level load (60-120s) ...')
    for t in (30, 60, 90, 120):
        time.sleep(30)
        h = shot(c, '05_load_t%d' % t); print('  +%ds:' % t, h)

    c.close()
    print('Done. Final shot should show 3D Doom gameplay.')


if __name__ == '__main__':
    sys.exit(main() or 0)
