"""Time-precise key probe — hit SPACE/RETURN AT the title screen.

From the v356_ext run we know post-SPACE-2:
  t490-t610: gray load phase
  t610-t670: TITLE SCREEN (B.J. + Nazi)
  t730:      HIGH SCORES
  t790-t970: BLACK transition
  t1030+:    DEMO running

This test reloads Wolf3D fresh, presses SPACE x2 (setup confirm), waits
for title screen (240s = 60s after expected start), then spams SPACE.
Captures hash before/after to see if game enters main menu.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'C64.rbf')
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/wolf3d.reu'
REU_MGL = '/tmp/load_wolf3d_reu.mgl'
LOADER_MGL = '/tmp/load_wolf3d_loader.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_title_break')

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


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    cn = run(c, 'cat /tmp/CORENAME').strip()
    if cn and cn != 'C64' and not cn.startswith('C64'):
        print('ABORT: CORENAME=%r' % cn); c.close(); return
    run(c, "echo 'agent=c64 task=wolf3d-title-break' > /tmp/mister_session.lock")

    print('Reloading Wolf3D ...')
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

    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    print('wait 180s for setup menu ...')
    time.sleep(180)
    keypress(c, 'space')
    print('SPACE 1 sent, wait 280s ...')
    time.sleep(280)
    keypress(c, 'space')
    print('SPACE 2 sent, wait for title screen (~120s) ...')

    # Sample every 30s during the load → title → highscore phase, looking
    # for the title screen. Once detected, spam keys.
    title_hash = None
    for i in range(8):  # 8 * 30s = 240s
        time.sleep(30)
        label = 't_phase%d' % i
        h = shot(c, label)
        print('  %s: %s' % (label, h))
        # Title screen is identifiable in v356_ext as hash 3a0b0f9f54 — won't
        # match here because RNG/state vary, but a 30s-stable hash indicates
        # a static screen, candidate for title or high-scores.

    # After all phases, press SPACE 5x rapidly (no wait) — Wolf3D needs
    # event during title to break to menu.
    print('\nSpam SPACE 5x ...')
    for i in range(5):
        keypress(c, 'space')
        time.sleep(2)
        h = shot(c, 'space_%d' % i)
        print('  space_%d: %s' % (i, h))

    # Try arrow + select sequence
    print('\nDown+ENTER to select MENU option ...')
    for k in ['down', 'down', 'return']:
        keypress(c, k); time.sleep(2)
        h = shot(c, 'menu_%s' % k); print('  %s: %s' % (k, h))

    c.close()
    print('Done. Captures in', OUT)


if __name__ == '__main__':
    main()
