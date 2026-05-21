#!/usr/bin/env python3
"""Generate test_mvn_pbr20.prg — exercise MVN block move from PBR=$20.

Hypothesis: Doom's bank-$20 prologue uses MVN $00,$20 to copy code from
bank $20 to bank $00, and our P65C816 implements MVN incorrectly under
some condition (turbo, bank crossings, source-from-program-bank, etc.).

Phase 1 (PBR=$00): copy phase-2 payload to bank $20:$0100 via STA [zp],Y
loop.
Phase 2 (PBR=$20):
  - REP #$30 (M=X=16)
  - Pre-populate bank $20:$0200..$020F with pattern $40,$41,$42,$43,$44,
    $45,$46,$47,$48,$49,$4A,$4B,$4C,$4D,$4E,$4F via STA [zp],Y to bank $20
    (zp pointer $58/$59/$5A = $20:$0200).
  - Setup: LDX #$0200, LDY #$0E0C, LDA #$000F (count-1)
  - MVN $00,$20  (opcode $54, then dst-bank $00, src-bank $20)
  - Verify bank $00:$0E0C..$0E1B = $40..$4F via LDA long
  - Border:
      green ($05) = all 16 bytes match
      red ($02) = first byte wrong
      yellow ($07) = first byte OK, but later byte wrong (count value visible)
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_mvn_pbr20.prg')

P2_BASE = 0x0100

# Phase 2 (PBR=$20). Enters with M=X=16 from phase 1.
p2 = bytes([
    # Marker: phase 2 entered (gray $0B).
    0xE2, 0x20,                  # SEP #$20 (M=8)
    0xA9, 0x0B,                  # LDA #$0B
    0x8D, 0x20, 0xD0,            # STA $D020
    0xC2, 0x20,                  # REP #$20 (M=16)

    # === Pre-populate $20:$0200..$020F with $40..$4F via STA [zp],Y ===
    # Setup zp $58/$59 = $0200, $5A = $20.
    0xA9, 0x00, 0x02,            # LDA #$0200
    0x85, 0x58,                  # STA $58 (lo+hi)
    0xE2, 0x20,                  # SEP #$20 (M=8)
    0xA9, 0x20,                  # LDA #$20
    0x85, 0x5A,                  # STA $5A (bank)
    # Unroll 16 STA [$58],Y stores, each writing $40+i at offset i.
    0xC2, 0x10,                  # REP #$10 (X=Y=16)
] + sum(([
    0xA9, 0x40 + i,              # LDA #$40+i (8-bit)
    0xA0, i, 0x00,               # LDY #i (16-bit)
    0x97, 0x58,                  # STA [$58],Y -> bank $20:$0200+i
] for i in range(16)), []) + [

    # === Prepare zp $50/$51/$52 = $00:$0E0C for read-back verify ===
    0xC2, 0x20,                  # REP #$20 (M=16)
    0xA9, 0x0C, 0x0E,            # LDA #$0E0C
    0x85, 0x50,                  # STA $50
    0xE2, 0x20,                  # SEP #$20 (M=8)
    0xA9, 0x00,                  # LDA #$00
    0x85, 0x52,                  # STA $52

    # === MVN $00, $20 from $20:$0200 to $00:$0E0C, count=16 ===
    0xC2, 0x30,                  # REP #$30 (M=X=16)
    0xA2, 0x00, 0x02,            # LDX #$0200 (source addr)
    0xA0, 0x0C, 0x0E,            # LDY #$0E0C (dest addr)
    0xA9, 0x0F, 0x00,            # LDA #$000F (count-1 = 15)
    0x54, 0x00, 0x20,            # MVN dst=$00, src=$20

    # === Verify bytes at $00:$0E0C..$0E1B === expected $40..$4F
    0xE2, 0x30,                  # SEP #$30 (M=X=8)
    # Default border = red.
    0xA9, 0x02,
    0x8D, 0x20, 0xD0,
    # Check first byte
    0xAF, 0x0C, 0x0E, 0x00,      # LDA $00:$0E0C
    0xC9, 0x40,                  # CMP #$40
    0xD0, 0x1F,                  # BNE +$1F (skip past green, default red)
    # First byte OK; default to yellow (means count was off / partial)
    0xA9, 0x07,
    0x8D, 0x20, 0xD0,
    # Check last byte
    0xAF, 0x1B, 0x0E, 0x00,      # LDA $00:$0E1B
    0xC9, 0x4F,                  # CMP #$4F
    0xD0, 0x12,                  # BNE +$12 (keep yellow)
    # Check middle byte
    0xAF, 0x14, 0x0E, 0x00,      # LDA $00:$0E14 (should be $48)
    0xC9, 0x48,                  # CMP #$48
    0xD0, 0x09,                  # BNE +9 (keep yellow)
    # All checks pass: green
    0xA9, 0x05,
    0x8D, 0x20, 0xD0,
    # Infinite loop
    0x4C, 0x00, 0x00,            # placeholder JMP self
])

# Patch JMP target — find the LAST 4C 00 00 sequence
jmp_idx = p2.rfind(bytes([0x4C, 0x00, 0x00]))
if jmp_idx < 0:
    raise SystemExit('JMP placeholder not found')
jmp_addr = P2_BASE + jmp_idx
p2 = p2[:jmp_idx + 1] + bytes([jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF]) + p2[jmp_idx + 3:]

# Phase 1 (runs from bank $00, PBR=$00) — copies p2 to bank $20:$0100
basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

phase1 = bytes([
    0x78,                            # SEI
    0xD8,                            # CLD
    0x8D, 0x7E, 0xD0,                # STA $D07E (SCPU enable)
    0x8D, 0x7B, 0xD0,                # STA $D07B (turbo)
    # Marker phase 1: cyan
    0xA9, 0x03,
    0x8D, 0x20, 0xD0,
    0x18,                            # CLC
    0xFB,                            # XCE
    # Setup zp pointer for byte copy: $50/$51/$52 = $20:$0100
    0xE2, 0x20,                      # SEP #$20 (M=8)
    0xA9, P2_BASE & 0xFF,
    0x85, 0x50,
    0xA9, (P2_BASE >> 8) & 0xFF,
    0x85, 0x51,
    0xA9, 0x20,
    0x85, 0x52,
    # Copy loop: STA [$50],Y from $0900,X. X=Y=16-bit.
    0xC2, 0x10,                      # REP #$10 (X=Y=16)
    0xA2, 0x00, 0x00,                # LDX #$0000
    0xA0, 0x00, 0x00,                # LDY #$0000
    0xBD, 0x00, 0x09,                # LDA $0900,X (M=8)
    0x97, 0x50,                      # STA [$50],Y
    0xE8,                            # INX
    0xC8,                            # INY
    0xC0, len(p2) & 0xFF, (len(p2) >> 8) & 0xFF,  # CPY #len
    0xD0, 0xF4,                      # BNE -12
    # Marker copy done: light gray $0F
    0xA9, 0x0F,
    0x8D, 0x20, 0xD0,
    # Switch M to 16 and JML
    0xC2, 0x20,                      # REP #$20 (M=16)
    0x5C, P2_BASE & 0xFF, (P2_BASE >> 8) & 0xFF, 0x20,  # JML $20:P2_BASE
])

PAD_TO = 0x0900
phase1_addr = 0x080D
phase1_end = phase1_addr + len(phase1)
pad = PAD_TO - phase1_end
if pad < 0:
    raise SystemExit('phase1 too long')

prg = bytes([0x01, 0x08]) + basic_stub + phase1 + bytes(pad) + p2
with open(OUT, 'wb') as f:
    f.write(prg)
print('phase1 size={}, ends at ${:04X}, pad {} -> ${:04X}'.format(
    len(phase1), phase1_end, pad, PAD_TO))
print('phase2 size={}'.format(len(p2)))
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
