"""v356 extended — deploy Wolf3D, reach post-SPACE-2 gray-screen state,
then sample every 60s for 10 min plus try RETURN+joystick-FIRE keys to
see if state changes. Hash-track screenshots for cheap change detection.

Outcome diagnoses next debug surface:
  Hash changes after a key → gray was just a hidden 'press X' prompt
  Hash stays constant → bitmap render is broken; need bitmap-mirror or
    VIC-bank/optim-mode investigation
"""
import os, time, hashlib, paramiko, re

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'C64.rbf')
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/wolf3d.reu'
REU_MGL = '/tmp/load_wolf3d_reu.mgl'
LOADER_MGL = '/tmp/load_wolf3d_loader.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v356_ext')

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


def uart_sample(c, label, seconds=3):
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout %d cat /dev/ttyS1 2>&1 | head -c 6000' % seconds, t=seconds+5)
    with open(os.path.join(OUT, label + '.txt'), 'w', errors='replace') as f:
        f.write(out)
    return out


def keypress(c, key):
    run(c, 'python3 /tmp/mtype.py %s 2>&1' % key, t=15)


def summarize_n(label, txt):
    ns = []
    for line in txt.split('\n'):
        m = re.search(r' N:([0-9A-Fa-f]{6})', line)
        if m: ns.append(m.group(1))
    if ns:
        banks = {}
        for n in ns: banks[n[:2]] = banks.get(n[:2], 0) + 1
        print('  [%s] N-banks: ' % label, end='')
        for b, cnt in sorted(banks.items()): print('%s(%d)' % (b, cnt), end=' ')
        print()


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    cn = run(c, 'cat /tmp/CORENAME').strip()
    if cn and cn != 'C64' and not cn.startswith('C64'):
        print('ABORT: CORENAME=%r' % cn); c.close(); return
    run(c, "echo 'agent=c64 task=wolf3d-v356-extended' > /tmp/mister_session.lock")

    print('upload v356 RBF (assuming already on disk, but make sure) ...')
    sftp = c.open_sftp()
    with open(RBF_LOCAL, 'rb') as f:
        with sftp.open(RBF_REMOTE, 'wb') as r: r.write(f.read())
    with open(LOADER_LOCAL, 'rb') as f:
        with sftp.open(LOADER_REMOTE, 'wb') as r: r.write(f.read())
    reu_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
               '<file delay="3" type="f" index="1" path="' + REU_REMOTE + '"/>\n'
               '</mistergamedescription>\n')
    loader_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                  '<file delay="3" type="f" index="1" path="' + LOADER_REMOTE + '"/>\n'
                  '</mistergamedescription>\n')
    with sftp.open(REU_MGL, 'w') as f: f.write(reu_mgl)
    with sftp.open(LOADER_MGL, 'w') as f: f.write(loader_mgl)
    with sftp.open(CFG, 'wb') as f: f.write(CFG_TURBO)
    sftp.close()

    print('load v356 RBF ...')
    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load wolf3d.reu (50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    print('wait 180s for setup menu ...')
    time.sleep(180)
    h = shot(c, 't180')
    print('  t180 hash: %s' % h)

    print('press SPACE 1, wait 280s ...')
    keypress(c, 'space')
    time.sleep(280)
    h460 = shot(c, 't460_after_space1')
    print('  t460 hash: %s' % h460)

    print('press SPACE 2 (was wedge in v355) ...')
    keypress(c, 'space')
    time.sleep(30)
    h_start = shot(c, 't490_after_space2')
    print('  t490 hash: %s' % h_start)

    # Sample every 60s for 10 minutes
    print('\nExtended monitoring (10 min @ 60s sample) ...')
    prev_hash = h_start
    for i, delay in enumerate([60]*10):
        time.sleep(delay)
        label = 'monitor_t%d' % (490 + (i+1)*60)
        h = shot(c, label)
        u = uart_sample(c, label + '_uart', seconds=3)
        change = ' CHANGED' if h != prev_hash else ''
        print('  %s: hash=%s%s' % (label, h, change))
        summarize_n(label, u)
        prev_hash = h

    # After 10 min of nothing changing, try keys
    print('\nKey injection probe ...')
    for key in ['return', 'space', 'y', '1']:
        print('  pressing %s ...' % key)
        keypress(c, key); time.sleep(10)
        h = shot(c, 'key_%s' % key)
        change = ' CHANGED' if h != prev_hash else ''
        print('  after %s: hash=%s%s' % (key, h, change))
        prev_hash = h

    c.close()
    print('Done. Captures in', OUT)


if __name__ == '__main__':
    main()
