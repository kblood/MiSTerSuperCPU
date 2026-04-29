#!/usr/bin/env python3
"""Minimal REP test from bank $20 with PHP/PLA flag capture.

NOP-sled from bank $20 passes (test_bank20_nopsled.py), so consecutive
multi-byte fetch from SuperRAM works. Unrolled-doom-prologue test hangs on
REP #$30. This test isolates the question: "Does REP #$30 actually clear M
and X when executed from bank $20?" — by capturing the post-REP P byte
via PHP/PLA/STA and storing it as the marker.

Payload at $20:$0000 (entered from loader already in native mode, M=X=1):
    $20:$0000  C2 30       REP #$30    ; under test — should clear M, X
    $20:$0002  08          PHP         ; push P as it is right now (1 byte)
    $20:$0003  E2 30       SEP #$30    ; force A back to 8-bit for PLA
    $20:$0005  68          PLA         ; pop 1 byte into A
    $20:$0006  8D 3C 03    STA $033C   ; marker = captured P byte
    $20:$0009  6B          RTL

Both paths reach STA linearly — no BRK traps, no opcode length drift.

Expected P byte = I|M|X flags pattern (D cleared, C varies).
  REP cleared M,X  -> P bits 4,5 = 0 -> marker = 0x04 (= 4,   just I set)
  REP M,X stuck    -> P bits 4,5 = 1 -> marker = 0x34 (= 52,  I|M|X set)
  Other values     -> interesting — report raw hex
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152

PAYLOAD = [
    0xC2, 0x30,                 # REP #$30
    0x08,                       # PHP
    0xE2, 0x30,                 # SEP #$30
    0x68,                       # PLA
    0x8D, 0x3C, 0x03,           # STA $033C
    0x6B,                       # RTL
]


def build_loader():
    code = []
    code += [0x78, 0x18, 0xFB]                       # SEI CLC XCE -> native
    code += [0xE2, 0x30]                             # SEP #$30
    for i, b in enumerate(PAYLOAD):
        code += [0xA9, b]                            # LDA #imm
        code += [0x8F, i & 0xFF, (i >> 8) & 0xFF, 0x20]  # STA $20:i
    code += [0x22, 0x00, 0x00, 0x20]                 # JSL $20:$0000
    code += [0xFB, 0x58, 0x60]                       # XCE CLI RTS
    return code


D_CNT_LO = 0xDFE9
D_CNT_HI = 0xDFEA
D_DAT    = 0xDFEB
D_AHI    = 0xDFEC


def basic_lines(code):
    lines = []
    lines.append(f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 poke828,255')  # sentinel so we can tell if STA ran
    lines.append(f'30 sys{BASE}')
    lines.append('40 m=peek(828)')
    lines.append('50 ?"rep-php bank20"')
    lines.append('60 ?"marker:";m;"hex:";')
    lines.append('70 h=int(m/16):l=m-16*h')
    lines.append('80 ifh<10then?chr$(48+h);:goto100')
    lines.append('90 ?chr$(55+h);')
    lines.append('100 ifl<10then?chr$(48+l):goto120')
    lines.append('110 ?chr$(55+l)')
    lines.append('120 ?"4=rep ok 52=rep stuck 255=never ran"')
    lines.append(f'130 ?"cnt:";peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append(f'140 ?"dat:";peek({D_DAT});"ahi:";peek({D_AHI})')
    data_chunks = []
    chunk = []
    chunk_len = 9
    for b in code:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            data_chunks.append(chunk)
            chunk = [s]
            chunk_len = 9 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        data_chunks.append(chunk)
    ln = 200
    for c in data_chunks:
        lines.append(f'{ln} data' + ','.join(c))
        ln += 10
    return lines


def main():
    code = build_loader()
    print(f'loader {len(code)} bytes')
    if '--deploy' in sys.argv:
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        md.scp_to('tools/mtype.py', '/tmp/mtype.py')
        time.sleep(5)
    lines = basic_lines(code)
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'cmd len={len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'rc={rc}')
    if rc != 0:
        print(f'ERR: {err[:200]}')
        return 1
    time.sleep(5)
    out_png = 'bank20_rep_php.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    md.cmd_screen([out_png])
    print()
    print('Interpretation:')
    print('  marker=4   -> PASS: REP cleared M,X (P=I only)')
    print('  marker=52  -> FAIL: REP M,X stuck (P=I|M|X)')
    print('  marker=255 -> CPU hung before STA ran')
    print('  other      -> report raw hex')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
