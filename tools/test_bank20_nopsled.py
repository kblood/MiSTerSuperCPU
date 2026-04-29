#!/usr/bin/env python3
"""Multi-byte instruction fetch test from bank $20.

test_bank20_jsl_rtl.py proved single-byte fetch from $20:$0000 works ($6B RTL).
test_rep_unrolled_bank20.py hangs when REP #$30 runs at $20:$0004.

This test fills $20:$0000-$0007 with NOP NOP NOP NOP NOP NOP NOP RTL ($6B).
JSL $20:$0000 should execute 7 NOPs sequentially then RTL back.

PASS (marker=$42): consecutive multi-byte fetch from SuperRAM works.
FAIL (hang):       consecutive fetch is broken — pipeline race on back-to-back reads.

Keeps the CPU fully in emulation mode (doesn't do XCE inside the payload)
to exclude any XCE/native-transition interaction.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152

PAYLOAD = [
    0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA,  # 7x NOP
    0x6B,                                      # RTL
]


def build_loader():
    code = []
    code += [0x78, 0x18, 0xFB]           # SEI CLC XCE -> native
    code += [0xE2, 0x30]                 # SEP #$30
    for i, b in enumerate(PAYLOAD):
        code += [0xA9, b]                # LDA #imm
        code += [0x8F, i & 0xFF, (i >> 8) & 0xFF, 0x20]  # STA long $20:i
    code += [0x22, 0x00, 0x00, 0x20]     # JSL $20:$0000
    code += [0xA9, 0x42]                 # LDA #$42
    code += [0x8D, 0x3C, 0x03]           # STA $033C (marker)
    code += [0xFB, 0x58, 0x60]           # XCE CLI RTS
    return code


D_CNT_LO = 0xDFE9
D_CNT_HI = 0xDFEA
D_DAT    = 0xDFEB
D_AHI    = 0xDFEC


def basic_lines(code):
    lines = []
    lines.append(f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 poke828,0')
    lines.append(f'30 sys{BASE}')
    lines.append('40 ?"nopsled bank20"')
    lines.append('50 ?"marker:";peek(828);"(exp 66)"')
    lines.append(f'60 ?"cnt:";peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append(f'70 ?"dat:";peek({D_DAT});"ahi:";peek({D_AHI})')
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
    ln = 100
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
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'rc={rc}')
    if rc != 0:
        print(f'ERR: {err[:200]}')
        return 1
    time.sleep(4)
    md.cmd_screen(['bank20_nopsled.png'])
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
