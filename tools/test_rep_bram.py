#!/usr/bin/env python3
"""Hardware regression: REP #$30 in native mode, code in bank $00 BRAM.

Runs the same prologue Doom uses (CLC; XCE; REP #$30; LDA #imm) but from
$C000 in motherboard RAM / BRAM instead of from SuperRAM bank $20.

Code at $C000 (49152):
  78          SEI
  18          CLC
  FB          XCE         ; -> native
  E2 30       SEP #$30    ; force M=X=1 (works around the XCE native M/X bug)
  A9 00       LDA #$00    ; 8-bit
  8D 3C 03    STA $033C   ; pre-clear result lo (cassette buffer = 828)
  8D 3D 03    STA $033D   ; pre-clear result hi (829)
  C2 30       REP #$30    ; clear M and X  <-- instruction under test
  A9 BB AA    LDA #$AABB  ; 16-bit immediate (3 bytes) if M=0
  8D 3C 03    STA $033C   ; 16-bit store (low $BB at $033C, high $AA at $033D) if M=0
  E2 30       SEP #$30
  FB          XCE         ; -> emu
  58          CLI
  60          RTS

Discrimination:
  PASS (M cleared): $033C=$BB=187, $033D=$AA=170
  FAIL (M stuck=1): $033C=$BB=187, $033D=$00=0
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


CODE = [
    0x78,                    # SEI
    0x18,                    # CLC
    0xFB,                    # XCE
    0xE2, 0x30,              # SEP #$30
    0xA9, 0x00,              # LDA #$00
    0x8D, 0x3C, 0x03,        # STA $033C
    0x8D, 0x3D, 0x03,        # STA $033D
    0xC2, 0x30,              # REP #$30  <-- test
    0xA9, 0xBB, 0xAA,        # LDA #$AABB
    0x8D, 0x3C, 0x03,        # STA $033C
    0xE2, 0x30,              # SEP #$30
    0xFB,                    # XCE
    0x58,                    # CLI
    0x60,                    # RTS
]
BASE = 49152  # $C000


def basic_lines():
    lines = []
    lines.append(f'10 fori=0to{len(CODE)-1}:readd:poke{BASE}+i,d:next')
    lines.append('20 sys49152')
    lines.append('30 ?"pass 187,170 fail 187,0"')
    lines.append('40 ?peek(828);peek(829)')
    # DATA broken across multiple lines (C64 BASIC line limit ~80 chars)
    data_chunks = []
    chunk = []
    chunk_len = 8  # "50 data"
    for b in CODE:
        s = str(b)
        if chunk and chunk_len + 1 + len(s) > 70:
            data_chunks.append(chunk)
            chunk = [s]
            chunk_len = 8 + len(s)
        else:
            chunk.append(s)
            chunk_len += 1 + len(s)
    if chunk:
        data_chunks.append(chunk)
    ln = 50
    for c in data_chunks:
        lines.append(f'{ln} data' + ','.join(c))
        ln += 10
    return lines


def main():
    deploy = '--deploy' in sys.argv
    if deploy:
        print('=== deploy (wipes SDRAM, resets C64) ===')
        if md.cmd_deploy(['C64_MiSTer/output_files/C64.rbf']):
            return 1
        time.sleep(4)
        print('waiting 6s for KERNAL READY...')
        time.sleep(6)

    lines = basic_lines()
    print(f'=== type {len(lines)} BASIC lines + RUN (single mtype call) ===')
    tokens = []
    for line in lines:
        tokens.append("'" + line + "'")
        tokens.append('enter')
    tokens.append("'run'")
    tokens.append('enter')
    cmd = 'python3 /tmp/mtype.py ' + ' '.join(tokens)
    print(f'  cmd len={len(cmd)}')
    out, err, rc = md.ssh(cmd, timeout=180)
    print(f'  rc={rc}')
    if rc != 0:
        print(f'  OUT: {out[:300]}')
        print(f'  ERR: {err[:300]}')
        return 1

    print('waiting 4s for execution + PRINT...')
    time.sleep(4)

    out_png = sys.argv[sys.argv.index('--out')+1] if '--out' in sys.argv else 'test_rep_bram.png'
    print(f'=== screenshot -> {out_png} ===')
    md.cmd_screen([out_png])
    print()
    print('Expected PASS (M cleared): 187 170')
    print('Expected FAIL (M stuck):   187 0')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
