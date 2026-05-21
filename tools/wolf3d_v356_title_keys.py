"""Press keys precisely during title screen window (120-180s after SPACE 2).

Per v356_ext timeline: post-SPACE-2 gray 0-120s, then title 120-180s,
high scores 180-240s, black 240-540s, demo 540s+. Title-screen window
is small. Send keys during this 60s window and capture state.

Uses CURRENT Wolf3D state if loaded — does NOT redeploy.
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_title_keys')

CFG_TURBO = bytes([
    0x00, 0x40, 0x00, 0x00,
    0x00, 0x40, 0x62, 0x00,
    0x00, 0x00, 0x84, 0x00,
    0x00, 0x00, 0x00, 0x00,
])

KNOWN_TITLE_HASH = '3a0b0f9f54'  # from v356_ext run


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
    run(c, "echo 'agent=c64 task=wolf3d-title-keys' > /tmp/mister_session.lock")

    # Reload Wolf3D fresh
    print('Reload Wolf3D ...')
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

    # Original setup flow: SPACE 1 → 280s wait → SPACE 2 → wait for attract.
    print('180s setup wait ...'); time.sleep(180)
    keypress(c, 'space'); print('SPACE 1 sent')
    print('280s wait ...'); time.sleep(280)
    keypress(c, 'space'); print('SPACE 2 sent')

    # Now sample every 20s — find when the title screen appears, then
    # immediately spam keys.
    print('\nWatching for title screen (every 20s) ...')
    in_title = False
    for i in range(30):  # 30 * 20s = 600s window
        time.sleep(20)
        h = shot(c, 'w_t%03d' % ((i+1)*20))
        print('  t+%ds: %s' % ((i+1)*20, h))
        # If hash is stable AND looks 'big' (PNG > 5k bytes), we're on a real
        # screen (title or high scores). Try key.
        p = os.path.join(OUT, 'w_t%03d.png' % ((i+1)*20))
        sz = os.path.getsize(p) if os.path.exists(p) else 0
        if sz > 5000 and not in_title:
            print('    -> non-trivial screen (%d B), trying RETURN+SPACE+1' % sz)
            in_title = True
            for k in ['return', 'space', '1', 'y']:
                keypress(c, k); time.sleep(2)
                h2 = shot(c, 'press_%s_%d' % (k, (i+1)*20))
                print('    after %s: %s' % (k, h2))
            # After spamming, wait then continue probing
            time.sleep(10)

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
