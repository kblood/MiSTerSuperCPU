"""After demo death (HEALTH 0), watch what Wolf3D does next.
Wolf3D PC normally goes to high-scores entry / new game prompt.
Capture every 10s for 90s.
"""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v356_post_death')


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


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    prev = ''
    for i in range(12):
        time.sleep(10)
        label = 't%03d' % ((i+1)*10)
        h = shot(c, label)
        change = ' CHANGED' if h != prev else ''
        print('  %s: %s%s' % (label, h, change))
        prev = h

    # Then press SPACE+RETURN+1 to see if we can enter a menu now
    print('\nTrying SPACE/RETURN/1 after attract cycle complete ...')
    for k in ['space', 'return', '1', 'y', 'esc']:
        run(c, 'python3 /tmp/mtype.py %s' % k, t=15); time.sleep(5)
        h = shot(c, 'after_%s' % k)
        print('  %s: %s' % (k, h))

    c.close()
    print('Done.')


if __name__ == '__main__':
    main()
