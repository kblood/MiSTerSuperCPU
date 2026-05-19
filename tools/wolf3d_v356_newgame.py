"""Wolf3D is at main menu (Options). Hit RETURN to select 'New Game',
then capture episode/difficulty screens.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_newgame')


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

    print('Pre-action baseline:')
    b = shot(c, 'pre_menu')
    print('  pre_menu: %s' % b)

    # Try RETURN to select 'New Game'
    print('\nRETURN to select New Game ...')
    keypress(c, 'return'); time.sleep(3)
    h1 = shot(c, 'after_return'); print('  after_return: %s' % h1)
    time.sleep(5)
    h2 = shot(c, 'after_return_5s'); print('  after_return_5s: %s' % h2)

    # If still in menu, try SPACE instead (some C64 games use space as confirm)
    if h1 == b:
        print('\nRETURN had no effect. Trying SPACE ...')
        keypress(c, 'space'); time.sleep(3)
        h3 = shot(c, 'after_space'); print('  after_space: %s' % h3)

    # Now try difficulty selection
    print('\nRETURN (presumed difficulty/episode select) ...')
    keypress(c, 'return'); time.sleep(3)
    h4 = shot(c, 'difficulty_default'); print('  difficulty_default: %s' % h4)
    time.sleep(15)
    h5 = shot(c, 'difficulty_after_15s'); print('  difficulty_after_15s: %s' % h5)

    # Wait for level load
    print('\nWaiting 60s for level load ...')
    time.sleep(60)
    h6 = shot(c, 'level1_t60'); print('  level1_t60: %s' % h6)

    print('\nWaiting another 60s ...')
    time.sleep(60)
    h7 = shot(c, 'level1_t120'); print('  level1_t120: %s' % h7)

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
