#!/usr/bin/env python3
"""Definitive REP test: populate bank $20 with real doom prologue via CPU
STA long (proven-working path), then JSL there and see if REP actually
clears M — bypassing the broken doom.mgl loader entirely.

The test distinguishes two outcomes:
  PASS ($033C = $42 = 66): CPU executed the full doom prologue (SEI...STZ)
       at $20:$0000-$000F, then ran the success stub at $20:$0010 which
       set M=1 via SEP, loaded $42, and long-stored it to $00:$033C.
  FAIL ($033C = 0): Either REP #$30 at $20:$0004 did not clear M (so
       LDA #$0000 ran as 2-byte, landed on $00 byte at $20:$0008 as BRK),
       OR instruction fetch from bank $20 returned zeros (bank $20 is
       empty for instruction reads even though data reads work).

Bank $00 code at $C000:
  C000  78                SEI
  C001  18                CLC
  C002  FB                XCE            -> native, C=1, E=0
  C003  E2 30             SEP #$30       M=X=1
  C005  A2 18             LDX #$18       24 (count-1 for 25 bytes)
  C007  BD 18 C0          LDA $C018,X    read data byte
  C00A  9F 00 00 20       STA $200000,X  write to bank $20:$0000+X
  C00E  CA                DEX
  C00F  10 F6             BPL $C007      loop
  C011  22 00 00 20       JSL $20:$0000  call the populated code
  C015  FB                XCE            -> emu (C=1 from end of payload)
  C016  58                CLI
  C017  60                RTS
  C018  [25 bytes data]
        78 D8 18 FB C2 30 A9 00 00 5B A9 FF 01 1B 64 80   real doom prologue
        E2 30 A9 42 8F 3C 03 00 6B                       success stub:
                                                         SEP #$30, LDA #$42,
                                                         STA long $00:$033C, RTL

Before jumping, BASIC clears $033C to 0 so we can detect non-write.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152  # $C000

CODE = [
    # C000
    0x78,                          # SEI
    0x18,                          # CLC
    0xFB,                          # XCE
    0xE2, 0x30,                    # SEP #$30
    0xA2, 0x18,                    # LDX #$18
    # C007 (loop top)
    0xBD, 0x18, 0xC0,              # LDA $C018,X
    0x9F, 0x00, 0x00, 0x20,        # STA $200000,X
    0xCA,                          # DEX
    0x10, 0xF6,                    # BPL $C007
    # C011
    0x22, 0x00, 0x00, 0x20,        # JSL $20:$0000
    0xFB,                          # XCE
    0x58,                          # CLI
    0x60,                          # RTS
    # C018 (25-byte data blob)
    0x78, 0xD8, 0x18, 0xFB,        # SEI CLD CLC XCE
    0xC2, 0x30,                    # REP #$30  <-- the instruction under test
    0xA9, 0x00, 0x00,              # LDA #$0000 (3 bytes only if M=0)
    0x5B,                          # TCD
    0xA9, 0xFF, 0x01,              # LDA #$01FF
    0x1B,                          # TCS
    0x64, 0x80,                    # STZ $80
    # $20:$0010 — success stub
    0xE2, 0x30,                    # SEP #$30 (force 8-bit)
    0xA9, 0x42,                    # LDA #$42 (8-bit)
    0x8F, 0x3C, 0x03, 0x00,        # STA long $00:$033C
    0x6B,                          # RTL (long return)
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
    lines.append('20 poke828,0:poke829,0')  # zero the success marker + spare
    lines.append(f'30 cb=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append(f'40 sys{BASE}')
    lines.append(f'50 ca=peek({D_CNT_LO})+256*peek({D_CNT_HI})')
    lines.append('60 ?"rep-real-bank20 v1"')
    lines.append('70 ?"marker($033c):";peek(828)')
    lines.append('80 ?"66=pass rep cleared m"')
    lines.append('90 ?"0=fail rep m stuck or bank20 unreadable"')
    lines.append('100 ?"srrcnt:";cb;"->";ca;"d:";ca-cb')
    lines.append(f'110 ?"last-dat:";peek({D_DAT});"ahi:";peek({D_AHI});"cbk:";peek({D_CBK})')
    lines.append(f'120 ?"last-a16:";peek({D_ALO})+256*peek({D_AMI})')
    # Data lines
    data_chunks = []
    chunk = []
    chunk_len = 10  # "130 data"
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
    ln = 130
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
        print(f'  OUT: {out[:200]}')
        print(f'  ERR: {err[:200]}')
        return 1

    # Wait longer — if the test crashes, BASIC never prints and screen stays dark
    print('\nwaiting 5s for BASIC execution/crash...')
    time.sleep(5)

    out_png = 'rep_real_bank20.png'
    if '--out' in sys.argv:
        out_png = sys.argv[sys.argv.index('--out') + 1]
    print(f'\n=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    print()
    print('Interpretation:')
    print('  marker($033c)=66 -> PASS: REP cleared M and prologue ran to stub')
    print('  marker($033c)=0  -> FAIL: REP M stuck OR bank $20 fetch gave zeros')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
