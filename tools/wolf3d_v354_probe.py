"""v354 probe — capture Wolf3D IRQ handler bytes $00:$2206-$220B.

v353 captured $00:$2200-$2205 = E2 20 AD 06 37 8D
  = SEP #$20; LDA $3706; STA ???
v354 changes the gate from cases $0-$5 to cases $6-$B to capture
$00:$2206-$220B which gives the STA target + next instruction.

Hypothesis: handler is reading $3706 (maybe IRQ pending byte / dispatch
index) and writing it somewhere — if STA target reveals $D019, it's
raster ack; $DC0D = CIA1; $DF09 = REU. WP shows last write was to
$220A, suggesting self-modifying code at $220A.

Output: tools/wolf3d_v354/
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v354')

# Smart Turbo + 4x speed + REU 16MB + SCPU On
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


def parse_v_bytes(uart_text):
    """For v354: V0..V5 = bytes at $00:$2206-$220B."""
    v_records = []
    for line in uart_text.split('\n'):
        m = re.search(r'V:([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})', line)
        yx = re.search(r'YX:([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})', line)
        pc = re.search(r'PC:([0-9A-Fa-f]{6})', line)
        nm = re.search(r' N:([0-9A-Fa-f]{6})', line)
        wp = re.search(r'WP:([0-9A-Fa-f]{6})', line)
        if m and yx:
            v_records.append({
                'bytes': [int(g, 16) for g in m.groups()] + [int(yx.group(1), 16), int(yx.group(2), 16)],
                'pc': pc.group(1) if pc else '??',
                'n':  nm.group(1) if nm else '??',
                'wp': wp.group(1) if wp else '??',
            })
    return v_records


def keypress(c, key):
    run(c, 'python3 /tmp/mtype.py %s 2>&1' % key, t=15)


def hash_png(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:10]


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    cn = run(c, 'cat /tmp/CORENAME').strip()
    if cn and cn != 'C64' and not cn.startswith('C64'):
        print('ABORT: CORENAME=%r' % cn); c.close(); return
    run(c, "echo 'agent=c64 task=wolf3d-v354-probe' > /tmp/mister_session.lock")

    print('upload v354 RBF ...')
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

    print('load v354 RBF + cfg ...')
    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load wolf3d.reu (50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    print('wait 180s for setup menu ...')
    time.sleep(180)
    shot(c, 't180_setup_menu')
    uart_sample(c, 't180_uart', 4)
    h1 = hash_png(os.path.join(OUT, 't180_setup_menu.png'))
    print('  t180: hash=%s' % h1)

    print('press SPACE 1 ...')
    keypress(c, 'space')
    time.sleep(280)
    shot(c, 't460_after_space1')
    uart_sample(c, 't460_uart', 4)

    print('press SPACE 2 (wedge trigger) ...')
    keypress(c, 'space')
    time.sleep(60)
    shot(c, 't520_wedge')

    txt = uart_sample(c, 't520_wedge_uart', 8)

    recs = parse_v_bytes(txt)
    if recs:
        print('\n=== Captured %d UART lines with V-bytes ===' % len(recs))
        seen = set()
        for r in recs:
            sig = tuple(r['bytes'])
            if sig not in seen:
                seen.add(sig)
                b = r['bytes']
                print('  WP=%s N=%s  bytes $2206-$220B = %02x %02x %02x %02x %02x %02x' % (
                    r['wp'], r['n'], b[0], b[1], b[2], b[3], b[4], b[5]))
        print('Total unique V patterns:', len(seen))
        last = recs[-1]
        b = last['bytes']
        print('\nLAST: N=%s WP=%s PC=%s  $2206-$220B = %02x %02x %02x %02x %02x %02x' % (
            last['n'], last['wp'], last['pc'], b[0], b[1], b[2], b[3], b[4], b[5]))

        # Decode the STA at $2205+ — what is $2205 byte addressing?
        # We know $2205 = $8D (STA absolute opcode), so $2206-$2207 = STA target lo/hi.
        if recs:
            b = recs[-1]['bytes']
            sta_target = b[0] | (b[1] << 8)
            print('\n>>> STA target = $%04X (from bytes $2206=%02x, $2207=%02x)' % (sta_target, b[0], b[1]))
            print('>>> Next opcode at $2208 = $%02x' % b[2])
            if sta_target == 0xD019:
                print('>>> $D019 = VIC IRQ ack (write-1-clear)')
            elif sta_target == 0xDC0D:
                print('>>> $DC0D = CIA1 ICR (read to ack)')
            elif sta_target == 0xDD0D:
                print('>>> $DD0D = CIA2 ICR (NMI source)')
            elif sta_target == 0xDF09:
                print('>>> $DF09 = REU Interrupt Mask Register')
            elif (sta_target & 0xFF00) == 0x2200:
                print('>>> self-modifying STA at $%04X' % sta_target)

    c.close()
    print('Done. UART captures in', OUT)


if __name__ == '__main__':
    main()
