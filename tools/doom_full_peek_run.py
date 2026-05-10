#!/usr/bin/env python3
"""Capture UART during Doom FULL-LOADER run on the v275 build that
repurposes the mem_5C peek to capture c64 bank $00 RAM at $6C03.

Uses /media/fat/_Test/doom_full_abs.mgl (loader.prg + doom.reu, the SAME
init path VICE oracle uses). Replaces the minlaunch path which skipped
the loader.

Compare histogram against doom_minlaunch's:
- minlaunch result: $AB 97%, $00 3% (bank-$20 hits dominate, bank-$00:6C03 = 0)
- full-loader expected (if loader populates $6C03): mostly $F4 (matching VICE)
- full-loader BAD (if loader fails too): same as minlaunch
"""
import os, time, paramiko, base64, re
from collections import Counter

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
MGL_REMOTE = '/media/fat/_Test/doom_full_abs.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full_peek')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    # cfg byte 10 = 0x84 (SCPU + UART)
    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")

    print('reload core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('load doom full-loader MGL ...')
    run(c, 'echo load_core ' + MGL_REMOTE + ' > /dev/MiSTer_cmd')
    # full loader is significantly slower than minlauncher — needs time
    # for 16 MB REU FETCH + bank decompression. Sleep 90s to give it room.
    print('settle 90s for loader to finish ...')
    time.sleep(90)

    print('15s UART capture ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1', t=22)
    os.makedirs(OUT, exist_ok=True)
    out_path = os.path.join(OUT, 'uart_15s_full.txt')
    with open(out_path, 'w', errors='replace') as f:
        f.write(out)

    g_re = re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
    pc_re = re.compile(r'PC:([0-9A-Fa-f]{6})')

    g_vals = g_re.findall(out)
    pc_vals = pc_re.findall(out)
    if not g_vals:
        print('No G: matches in UART output. UART format may have changed.')
        return
    print('Total samples: {}'.format(len(g_vals)))
    peek_ctr = Counter(g[2] for g in g_vals)
    print('Histogram of byte at $00:$6C03:')
    for v, cnt in peek_ctr.most_common():
        print('  ${} -> {} ({:.1f}%)'.format(v.upper(), cnt, 100*cnt/len(g_vals)))

    pc_ctr = Counter(pc_vals)
    print()
    print('PC histogram (top 5):')
    for pc, cnt in pc_ctr.most_common(5):
        print('  ${} -> {} ({:.1f}%)'.format(pc.upper(), cnt, 100*cnt/len(pc_vals)))

    # Take screenshot too for visual confirmation
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        lp = os.path.join(OUT, 'screen.png')
        sftp.get(rp, lp)
        sftp.close()
        print('saved -> ' + lp)

    c.close()


if __name__ == '__main__':
    main()
