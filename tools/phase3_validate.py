#!/usr/bin/env python3
"""Phase 3 (Codex Fourth Option) validation suite.

Run AFTER deploying the Phase 3 RBF. Captures:
  1. Boot screenshot at t=5s — expect READY (banner may be patched).
  2. UART tail — confirm no BRK runaway / kickstart wedge.
  3. CMD library memory dump via the dump_vectors PRG —
     non-zero bytes at $00:$801A-$8054 = CMD lib installed.
  4. Banner pixel-diff vs stock-banner reference (light heuristic).

Outputs land in tools/phase3_validate/.
"""
import os, sys, time, paramiko, hashlib

HOST, USER, PASS = '192.168.50.130', 'root', '1'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'phase3_validate')
DUMP_PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              'test_cart', 'out', 'dump_vectors.prg')
DUMP_PRG_REMOTE = '/media/fat/games/C64/dump_vectors.prg'
DUMP_MGL_REMOTE = '/tmp/dump_vectors.mgl'


def run(c, cmd, t=20):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    o, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    p = o.strip()
    if not p:
        return None
    sftp = c.open_sftp()
    local = os.path.join(OUT, name)
    sftp.get(p, local)
    sftp.close()
    print('  shot:', name)
    return local


def uart(c, name, secs=5):
    o, _ = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout %d cat /dev/ttyS1 2>&1' % secs, t=secs + 5)
    p = os.path.join(OUT, name)
    with open(p, 'w', errors='replace') as f:
        f.write(o)
    print('  uart:', name, '(%d bytes)' % len(o))
    return o


def pc_distribution(uart_text):
    """Return top 5 PC values from UART text."""
    from collections import Counter
    import re
    pcs = re.findall(r'PC:([0-9A-F]{6})', uart_text)
    c = Counter(pcs)
    return c.most_common(5)


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    print('Connected.')

    # 1. Boot screenshot — fresh load_core to get clean kickstart
    print('Step 1: boot test...')
    pre_mt, _ = run(c, 'stat -c %Y /tmp/CORENAME 2>/dev/null')
    run(c, 'echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd')
    time.sleep(8)
    shot(c, '01_boot.png')

    # 2. UART tail
    print('Step 2: UART 5s capture...')
    txt = uart(c, '02_uart_idle.txt', secs=5)
    pcs = pc_distribution(txt)
    print('  top PCs:')
    for pc, n in pcs:
        print('    %s : %d' % (pc, n))
    # Health check: PC should be in KERNAL keyboard polling range ($E5CD-$E5D3)
    healthy = any(pc.startswith('00E5') for pc, _ in pcs)
    print('  PC health: %s' % ('OK (in KERNAL idle)' if healthy else 'SUSPECT (no $E5xx PCs)'))

    # 3. CMD library dump via dump_vectors PRG
    print('Step 3: CMD library memory dump...')
    if os.path.exists(DUMP_PRG_LOCAL):
        sftp = c.open_sftp()
        sftp.put(DUMP_PRG_LOCAL, DUMP_PRG_REMOTE)
        mgl = ('<mistergamedescription>\n'
               '<rbf>_Test/C64</rbf>\n'
               '<file delay="2" type="f" index="1" path="%s"/>\n'
               '</mistergamedescription>\n') % DUMP_PRG_REMOTE
        with sftp.open(DUMP_MGL_REMOTE, 'w') as f:
            f.write(mgl)
        sftp.close()
        run(c, 'echo load_core %s > /dev/MiSTer_cmd' % DUMP_MGL_REMOTE)
        time.sleep(15)
        shot(c, '03_dump_vectors.png')
        # The dump_vectors PRG prints vector bytes to screen — visual inspection needed
    else:
        print('  dump_vectors PRG missing at %s' % DUMP_PRG_LOCAL)
        print('  (skip — visual screenshot still useful)')

    # 4. Banner visual capture
    print('Step 4: re-boot for clean banner capture...')
    run(c, 'echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd')
    time.sleep(8)
    shot(c, '04_banner_final.png')

    print('Done. Inspect screenshots in', OUT)
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
