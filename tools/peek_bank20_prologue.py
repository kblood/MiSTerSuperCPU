#!/usr/bin/env python3
"""Peek bank $20 bytes $0000..$0007 (Doom's native-mode prologue).

Distinguishes DMA load corruption from read-path corruption:
  - If $20:$0005 reads as $30, SuperRAM has the right byte ->bug is in the
    read pipeline during REP immediate fetch (cache, sdram_superram latch,
    3-stage pipeline timing).
  - If $20:$0005 reads as $10 (or anything non-$30), DMA load corrupted
    the byte ->bug is in the ioctl/REU load path.

Workflow:
  1. Deploy core (wipes SDRAM)
  2. Copy RBF to _Computer path (and versioned name) for MGL
  3. Load doom.mgl via MiSTer_cmd pipe (fills SDRAM bank $20)
  4. Wait ~20s for REU transfer
  5. Type BASIC loader that POKEs 65816 ML at $C000 and SYS's it
  6. ML does 8 × {LDA long $20:xxxx; STA $033C+i} via 24-bit LDA long
  7. Type `for i=0 to 7:?peek(828+i);:next` and screenshot

Expected Doom prologue bytes (from doom.reu offset 0x200000):
  $00=$78 (SEI) $01=$D8 (CLD) $02=$18 (CLC) $03=$FB (XCE)
  $04=$C2 (REP) $05=$30 (#$30 operand — this is the smoking gun)
  $06=$A9 (LDA)  $07=$00 (lo)
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF = "C64_MiSTer/output_files/C64.rbf"
BASE = 49152  # $C000


def build_code():
    """Build 65816 ML that reads $20:$0000..$0007 into $033C..$0343,
    plus a sanity-check read $00:$FFFC (reset vector low) to $0344."""
    code = [
        0x78,                          # SEI
        0x18,                          # CLC
        0xFB,                          # XCE         -> native
        0xE2, 0x30,                    # SEP #$30    (M=X=1 baseline)
    ]
    # Signature write so we know ML ran
    code += [0xA9, 0x5A, 0x8D, 0x45, 0x03]   # LDA #$5A; STA $0345
    for i in range(8):
        code += [0xAF, i, 0x00, 0x20]        # LDA $20:000i
        dst = 0x033C + i
        code += [0x8D, dst & 0xFF, (dst >> 8) & 0xFF]  # STA $033C+i
    # Sanity: LDA long $00:$FFFC (reset vector low) -> $0344
    code += [0xAF, 0xFC, 0xFF, 0x00, 0x8D, 0x44, 0x03]
    code += [
        0xFB,                          # XCE         -> emu
        0x58,                          # CLI
        0x60,                          # RTS
    ]
    return code


def basic_lines(code):
    lines = []
    lines.append(f'10 fori=0to{len(code)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 sys49152')
    lines.append('30 ?"bank20 $0000-$0007:"')
    lines.append('40 fori=0to7:?peek(828+i);:nexti:?""')
    lines.append('50 ?"want: 120 216 24 251 194 48 169 0"')
    lines.append('55 ?"$00:fffc=";peek(836);" sig=";peek(837)')
    # DATA lines
    per_line = 12
    ln = 60
    for i in range(0, len(code), per_line):
        chunk = code[i:i+per_line]
        lines.append(f'{ln} data' + ','.join(str(b) for b in chunk))
        ln += 10
    return lines


def main():
    deploy = '--deploy' in sys.argv

    if deploy:
        print('=== Step 1: Deploy core (wipes SDRAM) ===')
        if md.cmd_deploy([RBF]):
            return 1
        time.sleep(4)

        print('=== Step 2: Copy RBF to _Computer path ===')
        md.ssh('cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf')
        # Also cover the versioned MGL lookup path
        md.ssh('ls /media/fat/_Computer/C64_*.rbf 2>/dev/null '
               '| head -1 | xargs -r -I{} cp /media/fat/_Test/C64.rbf {}')

        print('=== Step 3: Load doom.mgl via MiSTer_cmd pipe ===')
        md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")
        print('waiting 20s for REU transfer...')
        time.sleep(20)

    print('=== Step 4: Type BASIC loader + RUN ===')
    code = build_code()
    lines = basic_lines(code)
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'  cmd len={len(cmd)}, code len={len(code)}')
    _, err, rc = md.ssh(cmd, timeout=180)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  ERR: {err[:300]}')
        return 1

    print('waiting 4s for execution...')
    time.sleep(4)

    out_png = sys.argv[sys.argv.index('--out')+1] if '--out' in sys.argv else 'peek_bank20_prologue.png'
    print(f'=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    print()
    print('Expected (uncorrupted): 120 216 24 251 194 48 169 0')
    print('If byte 5 reads 16 instead of 48 ->DMA load corruption.')
    print('If byte 5 reads 48 ->read-path bug (during REP immediate fetch).')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
