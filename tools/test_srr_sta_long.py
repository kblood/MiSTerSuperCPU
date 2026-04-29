#!/usr/bin/env python3
"""Write bank $20 via CPU STA long, read back via CPU LDA long.

Bypasses both doom.mgl loading AND the POKE $DF1D io_cycle write path.
Tests whether the CPU itself can populate a SuperRAM bank and read it
back — a direct round-trip through the 65C816 native-mode data path.

Code at $C000:
  SEI; CLC; XCE; SEP #$30      ; native, M=X=1
  LDA #$AB                     ; value
  STA long $200000             ; write bank $20 : $0000
  LDA #$CD                     ; second value
  STA long $200005             ; write bank $20 : $0005
  NOP NOP NOP NOP               ; drain any pipeline
  LDA long $200000             ; read back bank $20:$0000
  STA $033C                    ; store to 828
  LDA long $200005             ; read back bank $20:$0005
  STA $033D                    ; store to 829
  XCE; CLI; RTS

Expected (if both paths work):
  PEEK(828) = $AB = 171
  PEEK(829) = $CD = 205
  SRR delta = 2
  SRR last:  addr-hi=$20, cache-bk=$20, addr16=$0005, data=$CD=205
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152  # $C000

CODE = [
    0x78,                     # SEI
    0x18,                     # CLC
    0xFB,                     # XCE
    0xE2, 0x30,               # SEP #$30
    0xA9, 0xAB,               # LDA #$AB
    0x8F, 0x00, 0x00, 0x20,   # STA $200000  (STA long $20:$0000)
    0xA9, 0xCD,               # LDA #$CD
    0x8F, 0x05, 0x00, 0x20,   # STA $200005  (STA long $20:$0005)
    0xEA, 0xEA, 0xEA, 0xEA,   # NOP x4 (drain)
    0xAF, 0x00, 0x00, 0x20,   # LDA $200000  (LDA long $20:$0000)
    0x8D, 0x3C, 0x03,         # STA $033C
    0xAF, 0x05, 0x00, 0x20,   # LDA $200005  (LDA long $20:$0005)
    0x8D, 0x3D, 0x03,         # STA $033D
    0xFB,                     # XCE
    0x58,                     # CLI
    0x60,                     # RTS
]

# Diagnostic regs
D_CNT_LO = 0xDFE9
D_CNT_HI = 0xDFEA
D_DAT    = 0xDFEB
D_AHI    = 0xDFEC
D_CBK    = 0xDFED
D_ALO    = 0xDFEE
D_AMI    = 0xDFEF


def basic_lines():
    lines = []
    lines.append(f'10 fori=0to{len(CODE)-1}:readd:poke{BASE}+i,d:next')
    lines.append(f'20 cb=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append(f'30 sys{BASE}')
    lines.append(f'40 ca=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append('50 ?"srr-sta-long v1"')
    lines.append('60 ?"rb00:";peek(828);"(exp 171)"')
    lines.append('70 ?"rb05:";peek(829);"(exp 205)"')
    lines.append('80 ?"srrcnt:";cb;"->";ca;"d:";ca-cb;"(exp 2)"')
    lines.append(f'90 ?"lastdat:";peek({D_DAT});"ahi:";peek({D_AHI});"cbk:";peek({D_CBK})')
    lines.append(f'100 ?"lasta16:";peek({D_ALO})+256*peek({D_AMI})')
    # DATA lines
    data_chunks = []
    chunk = []
    chunk_len = 10  # "110 data"
    for b in CODE:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            data_chunks.append(chunk)
            chunk = [s]
            chunk_len = 10 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        data_chunks.append(chunk)
    ln = 110
    for c in data_chunks:
        lines.append(f'{ln} data' + ','.join(c))
        ln += 10
    return lines


def main():
    deploy = '--deploy' in sys.argv
    if deploy:
        print('=== deploy core (wipes SDRAM) ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(3)
        print('waiting 6s for KERNAL READY...')
        time.sleep(6)

    lines = basic_lines()
    print(f'\n=== type {len(lines)} BASIC lines + RUN ===')
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'  cmd len={len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=240)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  OUT: {out[:300]}')
        print(f'  ERR: {err[:300]}')
        return 1

    print('\nwaiting 4s for BASIC execution...')
    time.sleep(4)

    out_png = 'srr_sta_long_result.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    print(f'\n=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    print()
    print('Interpretation:')
    print('  rb00=171 rb05=205 -> CPU STA/LDA long to bank $20 works end-to-end')
    print('  rb00=0   rb05=0   -> write or read path broken (other banks broken too)')
    print('  rb00=171 rb05=0   -> second read failed (re-fetch race?)')
    print('  delta should be 2 (one per LDA long)')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
