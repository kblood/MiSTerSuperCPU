#!/usr/bin/env python3
"""Read the 128-entry trace ring buffer via $DF20-$DFE8 + page-select $DF1F.

The trace ring freezes on BRK/X-flip. Each entry is (PC_lo, PC_hi, PBR, IR).
4 pages x 32 entries = 128 entries. Write 0-3 to $DF1F to select page.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


def main():
    # BASIC program that iterates through 4 pages and prints the raw bytes.
    # Page select via POKE 57119,page (=$DF1F)
    # $DF20 (57120) = status byte: {wp[6:0], frozen}
    # Entries: $DF21..$DFA0 (32 entries × 4 bytes) = 57121..57248
    # P bytes: $DFC9..$DFE8 (32 bytes) = 57289..57320
    lines = [
        '10 ?"status:";peek(57120)',
        '20 forp=0to3:poke57119,p:?"pg"p":"',
        '30 fori=0to31',
        '40 ?i;"-";peek(57121+i*4);',
        '41 ?peek(57122+i*4);',
        '42 ?peek(57123+i*4);',
        '43 ?peek(57124+i*4);',
        '44 ?peek(57289+i)',
        '50 nexti:nextp',
    ]
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    tokens.append('wait:25')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'typing program...')
    _, err, rc = md.ssh(cmd, timeout=300)
    print(f'rc={rc}')
    time.sleep(3)
    out = sys.argv[sys.argv.index('--out')+1] if '--out' in sys.argv else 'trace.png'
    md.cmd_screen([out])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
