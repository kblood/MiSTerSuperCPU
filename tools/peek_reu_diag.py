#!/usr/bin/env python3
"""Read REU ioctl diagnostic registers via BASIC PEEK, one line each."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


def main():
    # Decimal addresses:
    # $DF09 = 57097 (ioctl cnt lo)
    # $DF0A = 57098 (mid)
    # $DF0B = 57099 (hi)
    # $DF0C = 57100 (ioctl idx)
    # $DF0D/E/F = 57101/2/3 (last addr lo/mid/hi)
    # $DF11 = 57105 (last data)
    # $DF12 = 57106 (byte0 data)
    # $DF1B = 57115 (readback byte)
    # $DF1C = 57116 (rb status)
    # $DFF0 = 57328 (prg dl count)
    lines = [
        '10 ?"cnt=";peek(57097);peek(57098);peek(57099)',
        '20 ?"idx=";peek(57100)',
        '30 ?"lastD=";peek(57105)',
        '40 ?"b0D=";peek(57106)',
        '50 ?"rbD=";peek(57115);"ST";peek(57116)',
        '60 ?"prg=";peek(57328)',
    ]
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'typing {len(lines)} lines...')
    _, err, rc = md.ssh(cmd, timeout=180)
    print(f'rc={rc}')
    if err and rc != 0:
        print('err:', err[:300])

    time.sleep(3)
    out = sys.argv[sys.argv.index('--out')+1] if '--out' in sys.argv else 'reu_diag.png'
    print(f'screenshot -> {out}')
    md.cmd_screen([out])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
