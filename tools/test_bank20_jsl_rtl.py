#!/usr/bin/env python3
"""Minimum viable JSL/RTL test: write ONE byte ($6B RTL) to bank $20:$0000
via plain STA long (no index), then JSL to it and see if we return.

If PEEK(828) = $42 after the test, everything worked:
  - STA long (non-indexed) wrote $6B to bank $20:$0000
  - JSL $20:$0000 jumped there
  - Instruction fetch from bank $20 returned $6B (RTL)
  - RTL returned to caller
  - Subsequent LDA #$42 / STA $033C executed

Code at $C000:
  78          SEI
  18          CLC
  FB          XCE              ; -> native (C=1, E=0)
  E2 30       SEP #$30         ; M=X=1
  A9 6B       LDA #$6B         ; the RTL byte
  8F 00 00 20 STA $200000      ; write $6B to $20:$0000 (non-indexed long)
  22 00 00 20 JSL $200000      ; call bank $20:$0000 (should fetch $6B = RTL)
  A9 42       LDA #$42
  8D 3C 03    STA $033C        ; marker: got past JSL/RTL
  FB          XCE              ; -> emu (C still 1)
  58          CLI
  60          RTS

If PEEK(828) = 0, either:
  - STA long (non-indexed) didn't write (would contradict earlier tests)
  - JSL didn't jump
  - Instruction fetch from bank $20 returns 0 (bank empty for fetch)
  - RTL broken
  - Or CPU crashed mid-sequence
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152

CODE = [
    0x78,                       # SEI
    0x18,                       # CLC
    0xFB,                       # XCE
    0xE2, 0x30,                 # SEP #$30
    0xA9, 0x6B,                 # LDA #$6B
    0x8F, 0x00, 0x00, 0x20,     # STA $200000
    0x22, 0x00, 0x00, 0x20,     # JSL $200000
    0xA9, 0x42,                 # LDA #$42
    0x8D, 0x3C, 0x03,           # STA $033C
    0xFB,                       # XCE
    0x58,                       # CLI
    0x60,                       # RTS
]


def basic_lines():
    lines = []
    lines.append(f'10 fori=0to{len(CODE)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 poke828,0')
    lines.append(f'30 sys{BASE}')
    lines.append('40 ?"jsl-rtl test"')
    lines.append('50 ?"marker:";peek(828);"(exp 66)"')
    lines.append(f'60 ?"srrdat:";peek({0xDFEB});"ahi:";peek({0xDFEC});"a16:";peek({0xDFEE})+256*peek({0xDFEF})')
    data_chunks = []
    chunk = []
    chunk_len = 9
    for b in CODE:
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
    ln = 70
    for c in data_chunks:
        lines.append(f'{ln} data' + ','.join(c))
        ln += 10
    return lines


def main():
    if '--deploy' in sys.argv:
        print('=== deploy core ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        print('re-uploading mtype.py...')
        md.scp_to('tools/mtype.py', '/tmp/mtype.py')
        time.sleep(5)

    lines = basic_lines()
    print(f'\n=== type {len(lines)} BASIC lines + RUN ===')
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  ERR: {err[:200]}')
        return 1

    time.sleep(4)
    md.cmd_screen(['bank20_jsl_rtl.png'])
    print('\nInterpretation:')
    print('  marker=66 -> JSL/RTL round-trip to bank $20 works')
    print('  marker=0  -> broken somewhere in the chain')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
