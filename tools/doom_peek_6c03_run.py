#!/usr/bin/env python3
"""Capture UART during Doom min-launcher run on the v275 build that
repurposes the mem_5C peek to capture c64 bank $00 RAM at $6C03.

UART output: G:## ## XX  where XX is the byte at $6C03 (formerly mem_5C).
Print histogram of XX values to determine what opcode is at the stuck PC.
"""
import os, time, paramiko, base64, re
from collections import Counter

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'doom_minlaunch.prg')
PRG_REMOTE = '/tmp/doom_minlaunch.prg'
MGL_REMOTE = '/tmp/doom_min.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_minlaunch')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def upload(c, local, remote):
    with open(local, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    run(c, 'rm -f {0}.b64 {0}'.format(remote))
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, remote))
    run(c, 'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(remote))


def write_mgl(c):
    mgl = (
        '<mistergamedescription>\n'
        '  <rbf>_Test/C64</rbf>\n'
        '  <file delay="3" type="f" index="1" path="/media/fat/games/C64/doom.reu"/>\n'
        '  <file delay="15" type="f" index="1" path="' + PRG_REMOTE + '"/>\n'
        '</mistergamedescription>\n'
    )
    run(c, 'rm -f ' + MGL_REMOTE)
    for line in mgl.split('\n'):
        if line.strip():
            run(c, "echo '" + line + "' >> " + MGL_REMOTE)


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    upload(c, PRG_LOCAL, PRG_REMOTE)
    write_mgl(c)
    # cfg byte 10 = 0x84 (SCPU + UART)
    run(c, "printf '\\x84' | dd of=" + CFG + " bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")

    print('reload core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    print('load doom min MGL ...')
    run(c, 'echo load_core ' + MGL_REMOTE + ' > /dev/MiSTer_cmd')
    time.sleep(45)  # wait for Doom to reach stuck-PC state

    print('15s UART capture ...')
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1', t=22)
    os.makedirs(OUT, exist_ok=True)
    out_path = os.path.join(OUT, 'uart_15s_v275.txt')
    with open(out_path, 'w', errors='replace') as f:
        f.write(out)

    # G:## ## ## extracts mem_40, mem_44, mem_5C (now 6C03 peek)
    g_re = re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
    pc_re = re.compile(r'PC:([0-9A-Fa-f]{6})')

    g_vals = g_re.findall(out)
    pc_vals = pc_re.findall(out)
    if not g_vals:
        print('No G: matches in UART output. UART format may have changed.')
        return
    print('Total samples: {}'.format(len(g_vals)))
    # 3rd byte is now $6C03 peek (formerly mem_5C)
    peek_ctr = Counter(g[2] for g in g_vals)
    print('Histogram of byte at \$00:\$6C03:')
    for v, cnt in peek_ctr.most_common():
        print('  ${} -> {} ({:.1f}%)'.format(v.upper(), cnt, 100*cnt/len(g_vals)))

    # PC histogram
    pc_ctr = Counter(pc_vals)
    print()
    print('PC histogram (top 5):')
    for pc, cnt in pc_ctr.most_common(5):
        print('  ${} -> {} ({:.1f}%)'.format(pc.upper(), cnt, 100*cnt/len(pc_vals)))

    c.close()


if __name__ == '__main__':
    main()
