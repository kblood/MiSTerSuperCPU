#!/usr/bin/env python3
"""Definitive REP test v2: populate bank $20:$0000-$0018 with the real doom
prologue using UNROLLED non-indexed STA long stores (no indexed variant,
no loop), then JSL there and check if REP actually clears M.

Why unrolled: test_rep_real_bank20.py hung the CPU when it used `STA long,X`
($9F) in a loop. test_bank20_jsl_rtl.py proved that a single non-indexed
`STA long` ($8F) + JSL + RTL round-trip to bank $20 works end-to-end. So we
use the proven-working $8F path for every byte.

Loader layout at $C000 (bank $00):
    SEI CLC XCE SEP #$30               (6 bytes)
    For each of 25 payload bytes:
      LDA #imm                         (2 bytes)
      STA $20:addr                     (4 bytes)
    JSL $20:$0000                      (4 bytes)
    XCE CLI RTS                        (3 bytes)

Payload at $20:$0000-$0018 (the real doom prologue + success stub):
    $20:$0000  78 D8 18 FB     SEI CLD CLC XCE  (enter native)
    $20:$0004  C2 30           REP #$30         <-- instruction under test
    $20:$0006  A9 00 00        LDA #$0000       (only 3-byte if M cleared)
    $20:$0009  5B              TCD
    $20:$000A  A9 FF 01        LDA #$01FF
    $20:$000D  1B              TCS
    $20:$000E  64 80           STZ $80
    $20:$0010  E2 30           SEP #$30         (back to 8-bit)
    $20:$0012  A9 42           LDA #$42
    $20:$0014  8F 3C 03 00     STA $00:$033C
    $20:$0018  6B              RTL

PASS ($033C = $42 = 66): REP cleared M, 16-bit LDA consumed the 2 zero bytes,
                         TCD/TCS/STZ executed, success stub ran, RTL returned.
FAIL ($033C = 0):        REP failed to clear M -> LDA #$00 ran as 2 bytes ->
                         CPU landed on next $00 byte as BRK -> never reached
                         success stub.

Diagnostic $DFE9-$DFEF latches still capture the LAST SuperRAM read the CPU
performed — useful to distinguish crash paths.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152  # $C000

# 25-byte payload that lives at $20:$0000
PAYLOAD = [
    0x78, 0xD8, 0x18, 0xFB,        # SEI CLD CLC XCE
    0xC2, 0x30,                    # REP #$30   <-- under test
    0xA9, 0x00, 0x00,              # LDA #$0000 (3-byte only if M=0)
    0x5B,                          # TCD
    0xA9, 0xFF, 0x01,              # LDA #$01FF
    0x1B,                          # TCS
    0x64, 0x80,                    # STZ $80
    0xE2, 0x30,                    # SEP #$30
    0xA9, 0x42,                    # LDA #$42
    0x8F, 0x3C, 0x03, 0x00,        # STA $00:$033C
    0x6B,                          # RTL
]


def build_loader():
    code = []
    code += [0x78, 0x18, 0xFB]           # SEI CLC XCE
    code += [0xE2, 0x30]                 # SEP #$30
    for i, b in enumerate(PAYLOAD):
        code += [0xA9, b]                # LDA #imm
        code += [0x8F,
                 i & 0xFF,
                 (i >> 8) & 0xFF,
                 0x20]                   # STA $20:i
    code += [0x22, 0x00, 0x00, 0x20]     # JSL $20:$0000
    code += [0xFB, 0x58, 0x60]           # XCE CLI RTS
    return code


D_CNT_LO = 0xDFE9
D_CNT_HI = 0xDFEA
D_DAT    = 0xDFEB
D_AHI    = 0xDFEC
D_CBK    = 0xDFED
D_ALO    = 0xDFEE
D_AMI    = 0xDFEF


def basic_lines(code):
    lines = []
    lines.append(f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 poke828,0')
    lines.append(f'30 cb=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append(f'40 sys{BASE}')
    lines.append(f'50 ca=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append('60 ?"rep-unrolled-bank20"')
    lines.append('70 ?"marker:";peek(828);"(exp 66)"')
    lines.append('80 ?"66=rep ok  0=rep m stuck"')
    lines.append('90 ?"srrcnt:";cb;"-";ca;"d:";ca-cb')
    lines.append(f'100 ?"dat:";peek({D_DAT});"ahi:";peek({D_AHI});"cbk:";peek({D_CBK})')
    lines.append(f'110 ?"a16:";peek({D_ALO})+256*peek({D_AMI})')

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
    print(f'loader size: {len(code)} bytes (base ${BASE:04X})')

    if '--deploy' in sys.argv:
        print('=== deploy core ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        print('re-uploading mtype.py...')
        md.scp_to('tools/mtype.py', '/tmp/mtype.py')
        time.sleep(5)

    lines = basic_lines(code)
    print(f'\n=== type {len(lines)} BASIC lines + RUN ===')
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'  cmd len={len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=300)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  ERR: {err[:200]}')
        return 1

    time.sleep(5)
    out_png = 'rep_unrolled_bank20.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    md.cmd_screen([out_png])

    print()
    print('Interpretation:')
    print('  marker=66 -> PASS: REP cleared M, prologue ran to success stub')
    print('  marker=0  -> FAIL: REP M stuck; LDA #$00 ran as 2-byte -> BRK')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
