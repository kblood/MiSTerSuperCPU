"""v355 probe — capture live values at $00:$3706-$370B + IRQ-source nibble.

v354 confirmed handler at $00:$2200-$220B reads $3706 and dispatches.
v355 changes:
  (a) Gate captures CPU reads at $00:$3706-$370B → V0..V5 = bytes the
      handler sees on every IRQ dispatch.
  (b) B6 field now packs IRQ source levels: B6 hi-nibble bits =
      {irq_vic_lvl, irq_cia1_lvl, irq_n_lvl, irq_ext_lvl}. Each bit is
      active-low (1 = no IRQ from that source, 0 = source asserted).
      Wedge with IF frozen: B6 hi-nibble tells WHICH source is stuck.

Expected wedge readings:
  B6:F0 — all sources clear (sourceless wedge — bug in CPU IRQ latch?)
  B6:E0 — irq_ext_n=0 → REU stuck (DF09 EI/intr bit)
  B6:B0 — irq_cia1=0 → CIA1 timer A or other CIA1 source stuck
  B6:70 — irq_vic=0 → VIC has another source besides raster
  B6:D0 — irq_n=0 → cartridge port (shouldn't happen for SCPU/REU game)

Output: tools/wolf3d_v355/
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wolf3d_v355')

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


def parse_v_b6(uart_text):
    """V0..V5 = bytes at $00:$3706-$370B; B6 = IRQ source nibble."""
    recs = []
    for line in uart_text.split('\n'):
        m = re.search(r'V:([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})', line)
        yx = re.search(r'YX:([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})', line)
        pc = re.search(r'PC:([0-9A-Fa-f]{6})', line)
        nm = re.search(r' N:([0-9A-Fa-f]{6})', line)
        wp = re.search(r'WP:([0-9A-Fa-f]{6})', line)
        b6 = re.search(r'B6:([0-9A-Fa-f]{2})', line)
        ifc = re.search(r'IF:([0-9A-Fa-f]{4})', line)
        if m and yx and b6:
            recs.append({
                'bytes': [int(g, 16) for g in m.groups()] + [int(yx.group(1), 16), int(yx.group(2), 16)],
                'pc': pc.group(1) if pc else '??',
                'n':  nm.group(1) if nm else '??',
                'wp': wp.group(1) if wp else '??',
                'b6': int(b6.group(1), 16),
                'if': ifc.group(1) if ifc else '??',
            })
    return recs


def decode_b6(b6):
    hi = (b6 >> 4) & 0xF
    src = []
    if not (hi & 0x8): src.append('irq_vic')
    if not (hi & 0x4): src.append('irq_cia1')
    if not (hi & 0x2): src.append('irq_n_cart')
    if not (hi & 0x1): src.append('irq_ext_reu')
    return ' + '.join(src) if src else 'NONE (all sources clear)'


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
    run(c, "echo 'agent=c64 task=wolf3d-v355-probe' > /tmp/mister_session.lock")

    print('upload v355 RBF ...')
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

    print('load v355 RBF + cfg ...')
    run(c, 'echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load wolf3d.reu (50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    print('wait 180s for setup menu ...')
    time.sleep(180)
    shot(c, 't180_setup_menu')
    uart_sample(c, 't180_uart', 4)

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

    recs = parse_v_b6(txt)
    if recs:
        print('\n=== Captured %d UART lines with V-bytes ===' % len(recs))
        # Show distribution of B6 values
        b6_seen = {}
        for r in recs:
            b6_seen[r['b6']] = b6_seen.get(r['b6'], 0) + 1
        print('\nB6 nibble distribution (wedge):')
        for b6, cnt in sorted(b6_seen.items()):
            print('  B6=%02X (count=%d) → IRQ asserted by: %s' % (b6, cnt, decode_b6(b6)))

        # Show unique V byte combos
        seen = set()
        for r in recs:
            sig = tuple(r['bytes'])
            if sig not in seen:
                seen.add(sig)
                b = r['bytes']
                print('  $3706-$370B = %02x %02x %02x %02x %02x %02x  B6=%02X IF=%s' % (
                    b[0], b[1], b[2], b[3], b[4], b[5], r['b6'], r['if']))
        print('Total unique V patterns:', len(seen))
        last = recs[-1]
        b = last['bytes']
        print('\nLAST: B6=%02X IF=%s  $3706-$370B = %02x %02x %02x %02x %02x %02x' % (
            last['b6'], last['if'], b[0], b[1], b[2], b[3], b[4], b[5]))

    c.close()
    print('Done. UART captures in', OUT)


if __name__ == '__main__':
    main()
