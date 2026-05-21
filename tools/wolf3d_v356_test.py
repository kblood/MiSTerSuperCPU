"""v356 TEST — verify REU IRQ stuck wedge is fixed.

v356 RTL changes:
  1. $FFEE/$FFEF reads forced to $00/$FF (route ALL IRQ to $FF00 stub)
  2. Stub-tail $FF2A-$FF2D JML reads scpu_native_vec(10/11) when
     scpu_irq_vec_installed='1' (set on first write to $FFEE/$FFEF),
     else falls back to $0D3C (v350 Doom behaviour).

Expected behaviour:
  Setup menu: SAME as v355 (B6:F0, IF advancing, screen shows menu)
  After SPACE 1: SAME ("Working..." → next "Press a key")
  After SPACE 2 (was wedge in v355): B6:F0 still, IF advancing, main
    thread N: advances past $0F:$A643. Game should now progress to
    next state (NEW MISSION / EPISODE prompt, or in-game start).

If B6 still shows $E0 → fix didn't work / different bug.
If B6:F0 but screen still frozen → IRQ chain fixed but main thread
  blocked on something else (probably a stubbed SCPU reg poll).
"""
import os, time, hashlib, paramiko, re, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'C64.rbf')
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/wolf3d.reu'
REU_MGL = '/tmp/load_wolf3d_reu.mgl'
LOADER_MGL = '/tmp/load_wolf3d_loader.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v356')

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


def uart_sample(c, label, seconds=6):
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout %d cat /dev/ttyS1 2>&1 | head -c 12000' % seconds, t=seconds+5)
    with open(os.path.join(OUT, label + '.txt'), 'w', errors='replace') as f:
        f.write(out)
    return out


def keypress(c, key):
    run(c, 'python3 /tmp/mtype.py %s 2>&1' % key, t=15)


def hash_png(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:10]


def decode_b6(b6):
    hi = (b6 >> 4) & 0xF
    src = []
    if not (hi & 0x8): src.append('VIC')
    if not (hi & 0x4): src.append('CIA1')
    if not (hi & 0x2): src.append('CART')
    if not (hi & 0x1): src.append('REU')
    return '+'.join(src) if src else 'CLEAR'


def summarize_uart(label, txt):
    """Pull B6, IF, N, VW from each line for diagnostic."""
    b6s, ifs, ns = [], [], []
    for line in txt.split('\n'):
        m = re.search(r'B6:([0-9A-Fa-f]{2})', line)
        if m: b6s.append(int(m.group(1), 16))
        m = re.search(r'IF:([0-9A-Fa-f]{4})', line)
        if m: ifs.append(int(m.group(1), 16))
        m = re.search(r' N:([0-9A-Fa-f]{6})', line)
        if m: ns.append(m.group(1))
    if b6s:
        b6_unique = {}
        for b in b6s: b6_unique[b] = b6_unique.get(b, 0) + 1
        print('  [%s] B6 distribution: ' % label, end='')
        for b6, cnt in sorted(b6_unique.items()):
            print('%02X(%d, %s)' % (b6, cnt, decode_b6(b6)), end=' ')
        print()
        if ifs:
            print('  [%s] IF range: $%04X -> $%04X (delta=%d)' % (
                label, ifs[0], ifs[-1], ifs[-1]-ifs[0]))
        if ns:
            n_unique = set(ns)
            if len(n_unique) > 8:
                print('  [%s] N: %d unique values (main thread moving)' % (label, len(n_unique)))
            else:
                print('  [%s] N: %s' % (label, sorted(n_unique)))


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    cn = run(c, 'cat /tmp/CORENAME').strip()
    if cn and cn != 'C64' and not cn.startswith('C64'):
        print('ABORT: CORENAME=%r' % cn); c.close(); return
    run(c, "echo 'agent=c64 task=wolf3d-v356-test' > /tmp/mister_session.lock")

    print('upload v356 RBF ...')
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

    print('load v356 RBF + cfg ...')
    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load wolf3d.reu (50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    print('wait 180s for setup menu ...')
    time.sleep(180)
    shot(c, 't180_setup_menu')
    t180_txt = uart_sample(c, 't180_uart', 4)
    summarize_uart('t180', t180_txt)

    print('press SPACE 1 ...')
    keypress(c, 'space')
    time.sleep(280)
    shot(c, 't460_after_space1')
    t460_txt = uart_sample(c, 't460_uart', 4)
    summarize_uart('t460', t460_txt)

    print('press SPACE 2 (was wedge in v355) ...')
    keypress(c, 'space')
    time.sleep(60)
    shot(c, 't520_after_space2')
    t520_txt = uart_sample(c, 't520_uart', 8)
    summarize_uart('t520', t520_txt)

    # Watch another 60s for further progress
    print('extended wait +60s (probe for game progression) ...')
    time.sleep(60)
    shot(c, 't580_extended')
    t580_txt = uart_sample(c, 't580_uart', 8)
    summarize_uart('t580', t580_txt)

    # Hashes
    print('\n=== Screenshot hashes ===')
    for label in ['t180_setup_menu', 't460_after_space1', 't520_after_space2', 't580_extended']:
        p = os.path.join(OUT, label + '.png')
        if os.path.exists(p):
            print('  %s: %s' % (label, hash_png(p)))

    c.close()
    print('Done. Captures in', OUT)


if __name__ == '__main__':
    main()
