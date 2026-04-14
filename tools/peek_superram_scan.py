#!/usr/bin/env python3
"""Scan multiple SuperRAM banks to detect whether SDRAM is populated.

Reads 1 byte from each of bank $01:$0000, $02:$0000, $10:$0000, $20:$0000,
$20:$0005, $40:$0000, $80:$0000, $F0:$0000 into $033C-$0343. If ALL return 0,
the MGL REU load didn't populate SDRAM at all. If SOME are non-zero, we know
the load happened and can narrow down what's corrupted at bank $20.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

BASE = 49152

# (bank, addr16, label)
TARGETS = [
    (0x01, 0x0000, 'b01'),
    (0x02, 0x0000, 'b02'),
    (0x10, 0x0000, 'b10'),
    (0x20, 0x0000, 'b20_00'),
    (0x20, 0x0005, 'b20_05'),
    (0x40, 0x0000, 'b40'),
    (0x80, 0x0000, 'b80'),
    (0xF0, 0x0000, 'bF0'),
]


def build_code():
    code = [
        0x78,                          # SEI
        0x18,                          # CLC
        0xFB,                          # XCE     -> native
        0xE2, 0x30,                    # SEP #$30
    ]
    for i, (bank, addr16, _) in enumerate(TARGETS):
        code += [0xAF, addr16 & 0xFF, (addr16 >> 8) & 0xFF, bank]
        dst = 0x033C + i
        code += [0x8D, dst & 0xFF, (dst >> 8) & 0xFF]
    code += [0xFB, 0x58, 0x60]
    return code


def basic_lines(code):
    lines = []
    lines.append(f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 sys49152')
    lines.append('30 ?"scan:"')
    for i, (_, _, lbl) in enumerate(TARGETS):
        lines.append(f'{40+i} ?"{lbl}=";peek({828+i})')
    per = 12
    ln = 100
    for i in range(0, len(code), per):
        chunk = code[i:i+per]
        lines.append(f'{ln} data' + ','.join(str(b) for b in chunk))
        ln += 10
    return lines


def main():
    code = build_code()
    lines = basic_lines(code)
    tokens = []
    for ln in lines:
        tokens.append("'" + ln + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'cmd len={len(cmd)}, code len={len(code)}')
    out, err, rc = md.ssh(cmd, timeout=180)
    print(f'rc={rc}')
    time.sleep(4)
    md.cmd_screen(['peek_superram_scan.png'])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
