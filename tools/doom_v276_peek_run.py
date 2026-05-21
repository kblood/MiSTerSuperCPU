#!/usr/bin/env python3
"""v276 4-byte peek of bank $00:$6C00..$6C03 (gated to bank $00 only).

UART line slots:
  G:## ## ## — bytes 1+2 are $6C00 + $6C01 (formerly mem_40, mem_44)
              byte 3 is $6C03 (mem_5C, gated to bank $00)
  B:##       — $6C02 (mem_45, gated to bank $00)

Run sequence: full loader via doom_full_abs.mgl, settle 240s (well past
the ~150s loader→hang transition), capture 15s UART, decode 4 peek bytes.

Expected outcomes:
  All $00:    REU FETCH or long-store missed entire $6C00-$6C03 region
  Some $00:   partial write — narrow down which bytes survived
  Match VICE: $6C00=$3E, $6C01=$00, $6C02=$B7, $6C03=$F4 (real Doom code)
"""
import os, time, paramiko, re
from collections import Counter

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
MGL = '/media/fat/_Test/doom_full_abs.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_v276_peek')


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
    print('settle 240s for loader -> hang transition ...')
    time.sleep(240)

    print('15s UART capture ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1', t=22)
    out_path = os.path.join(OUT, 'uart_15s_v276.txt')
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
    print('Bank $00:$6C00..$6C03 byte distribution (last value across run):')
    addrs = ['$6C00', '$6C01', '$6C03']
    for i,addr in enumerate(addrs):
        ctr = Counter(g[i] for g in g_vals)
        print('  {} -> {}'.format(addr,
            ', '.join('${}={} ({:.0f}%)'.format(v.upper(), c, 100*c/len(g_vals))
                      for v,c in ctr.most_common(3))))
    if b_vals:
        bctr = Counter(b_vals)
        print('  $6C02 -> ' + ', '.join('${}={} ({:.0f}%)'.format(v.upper(), c, 100*c/len(b_vals))
                                         for v,c in bctr.most_common(3)))

    print()
    print('VICE expected: $6C00=$3E, $6C01=$00, $6C02=$B7, $6C03=$F4')
    print()
    print('PC histogram (top 5):')
    pc_ctr = Counter(pc_vals)
    for pc, cnt in pc_ctr.most_common(5):
        print('  ${} -> {} ({:.1f}%)'.format(pc.upper(), cnt, 100*cnt/len(pc_vals)))

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
