"""Apply the Wolf3D menu-break recipe to Doom on v356.

Sequence:
  1. Load Doom: doom_reu_only MGL (50s) → inject loader.prg → RUN → wait
     60s for REU→SuperRAM copy → launcher POKE+SYS.
  2. Wait through id Software credits and title screen.
  3. Every 20s, capture state. Try common menu-break keys (RETURN/SPACE/
     ESC/Y/1) at the first stable non-trivial screen we land on.
  4. Continue for ~15 min total, log all hashes + which keys advanced
     state.

Goal: reach Doom's main menu and start a new game.
"""
import os, time, hashlib, paramiko, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'C64.rbf')
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
REU_MGL = '/media/fat/_Test/doom_reu_only.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_menu_break')

CFG_TURBO = bytes([
    0x00, 0x40, 0x00, 0x00,
    0x00, 0x40, 0x62, 0x00,
    0x00, 0x00, 0x84, 0x00,
    0x00, 0x00, 0x00, 0x00,
])


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


def type_line(c, text):
    """Type text + enter via one mtype call (avoid 6s setup penalty per call)."""
    quoted = text.replace("'", "'\\''")
    run(c, "python3 /tmp/mtype.py '%s' enter" % quoted, t=30)


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    cn = run(c, 'cat /tmp/CORENAME').strip()
    if cn and cn != 'C64' and not cn.startswith('C64'):
        print('ABORT: CORENAME=%r' % cn); c.close(); return
    run(c, "echo 'agent=c64 task=doom-menu-break' > /tmp/mister_session.lock")

    # mtype.py upload (in case)
    local_mtype = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mtype.py')
    sftp = c.open_sftp()
    if os.path.exists(local_mtype):
        sftp.put(local_mtype, '/tmp/mtype.py')

    # v356 RBF + Turbo cfg
    print('upload v356 RBF + Turbo cfg ...')
    with open(RBF_LOCAL, 'rb') as f:
        with sftp.open(RBF_REMOTE, 'wb') as r: r.write(f.read())
    with sftp.open(CFG, 'wb') as f: f.write(CFG_TURBO)
    sftp.close()

    print('load v356 RBF ...')
    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu MGL (50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    shot(c, 'after_reu')
    print('inject loader.prg via mbc ...')
    run(c, 'mbc load_rom /media/usb0/games/C64/loader.prg C64', t=20); time.sleep(5)
    shot(c, 'after_loader')
    print('RUN to start loader (60s copy) ...')
    type_line(c, 'RUN'); time.sleep(60)
    shot(c, 'after_run')
    print('launcher POKE+SYS49152 ...')
    type_line(c, 'POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92')
    type_line(c, 'POKE49156,0:POKE49157,0:POKE49158,32')
    type_line(c, 'SYS49152'); time.sleep(3)
    shot(c, 'after_sys')

    # Now Doom is launched. Per v342 baseline, credits screen renders at
    # ~t485. Title + attract cycle starts after that. Monitor every 20s
    # for 16 min looking for stable screens.
    print('\nMonitoring Doom attract cycle (~16 min) ...')
    prev_hash = None
    stable_count = 0
    last_stable_hash = None
    triggered = {}
    for i in range(48):  # 48 * 20s = 960s = 16 min
        time.sleep(20)
        h = shot(c, 'm_%03d' % (i*20))
        marker = ''
        if h == prev_hash:
            stable_count += 1
            if stable_count >= 2 and h != last_stable_hash:
                # Newly stable screen (3+ samples = 40+ seconds same hash)
                last_stable_hash = h
                marker = ' STABLE'
                if h not in triggered:
                    triggered[h] = True
                    print('  t+%ds: %s%s -> probing keys ...' % (i*20, h, marker))
                    for k in ['return', 'space', 'esc', 'y', '1']:
                        keypress(c, k); time.sleep(2)
                        h2 = shot(c, 'k_%s_%d' % (k, i*20))
                        chg = ' CHANGED' if h2 != h else ''
                        print('    after %s: %s%s' % (k, h2, chg))
                    # After key probe, capture 2 more shots to see if state truly advanced
                    time.sleep(10)
                    h3 = shot(c, 'p_after_keys_%d' % (i*20))
                    print('    +10s: %s' % h3)
                    continue
        else:
            stable_count = 0
        print('  t+%ds: %s%s' % (i*20, h, marker))
        prev_hash = h

    c.close()
    print('Done. Captures in', OUT)


if __name__ == '__main__':
    sys.exit(main() or 0)
