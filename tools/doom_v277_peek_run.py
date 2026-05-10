#!/usr/bin/env python3
"""v277 cross-bank peek: bank $00 vs bank $2A at $6C00/$6C03.

UART line slots:
  G: byte 1 -> bank $00:$6C00 (mem_40)
  G: byte 2 -> bank $2A:$6C00 (mem_44)
  G: byte 3 -> bank $00:$6C03 (mem_5C)
  B: byte   -> bank $2A:$6C03 (mem_45)

Hypothesis matrix:
  Bank $2A:$6C00 = $3E AND bank $00:$6C00 = $AB:
    -> Source data is correct; cross-bank copy from $2A->$00 is the bug
  Bank $2A:$6C00 = $AB AND bank $00:$6C00 = $AB:
    -> Source data corrupted at REU FETCH stage; both banks have $AB
  Bank $2A:$6C00 = $00:
    -> Bank $2A SuperRAM was never written to (loader path failed)
  Bank $2A:$6C00 = $3E AND bank $00:$6C00 = $3E:
    -> Both correct; bug is elsewhere (not memory)
"""
import os, time, paramiko, re
from collections import Counter

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
MGL = '/media/fat/_Test/doom_full_abs.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_v277_peek')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    print('reload core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('load doom MGL ...')
    run(c, 'echo load_core ' + MGL + ' > /dev/MiSTer_cmd')
    print('settle 240s ...')
    time.sleep(240)

    print('15s UART capture ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1', t=22)
    out_path = os.path.join(OUT, 'uart_15s_v277.txt')
    with open(out_path, 'w', errors='replace') as f:
        f.write(out)

    g_re = re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
    b_re = re.compile(r'B:([0-9A-Fa-f]{2})')
    pc_re = re.compile(r'PC:([0-9A-Fa-f]{6})')
    g_vals = g_re.findall(out)
    b_vals = b_re.findall(out)
    pc_vals = pc_re.findall(out)

    if not g_vals:
        print('No G: matches.')
        return

    print('Total samples: {}'.format(len(g_vals)))
    print()
    print('Cross-bank peek histogram (last value seen):')
    addrs = ['$00:$6C00', '$2A:$6C00', '$00:$6C03']
    for i,addr in enumerate(addrs):
        ctr = Counter(g[i] for g in g_vals)
        print('  {} -> {}'.format(addr,
            ', '.join('${}={} ({:.0f}%)'.format(v.upper(), c, 100*c/len(g_vals))
                      for v,c in ctr.most_common(3))))
    if b_vals:
        bctr = Counter(b_vals)
        print('  $2A:$6C03 -> ' + ', '.join('${}={} ({:.0f}%)'.format(v.upper(), c, 100*c/len(b_vals))
                                             for v,c in bctr.most_common(3)))

    print()
    print('VICE expected: $00 and $2A both = $3E,$00,$B7,$F4 at $6C00..')

    # screenshot
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'screen.png'))
        sftp.close()

    c.close()


if __name__ == '__main__':
    main()
