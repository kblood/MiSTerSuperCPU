#!/usr/bin/env python3
"""Generate test_pbr20_m16.prg — exercise 16-bit M STA [zp] from PBR=$20.

Doom's prologue does REP #$30 (M=0, X=0) then 16-bit long stores. Hardware
hangs at PC=$6C03 with data bus consistently $6C (JMP indirect opcode),
suggesting bank $00 RAM at $6C03 is corrupt — long-store wrote wrong byte.
8-bit long stores from PBR=$20 to bank $00 PASS (test_pbr20_to_bank0.prg).
This test checks 16-bit ones.

Plan:
  Phase 1 (PBR=$00):
    - Enable SCPU + turbo, native, REP #$30 (M=0, X=0)
    - Copy small payload to bank $20 SuperRAM via STA [zp],Y (M=8) loop
    - JML to bank $20:$0100
  Phase 2 (PBR=$20):
    - REP #$30 (M=X=16)
    - Set up zp $50/$51/$52 = $00:$0E0C
    - LDA #$4342 ; STA [$50] (M=16)  -> bank $00:$0E0C..$0E0D = $42 $43
    - LDY #$0002 ; LDA #$4544 ; STA [$50],Y (M=16) -> $00:$0E0E..$0E0F = $44 $45
    - SEP #$20 (M=8); read back via LDA long; compare; set border:
        green ($05) = all 4 bytes correct
        yellow ($07) = first 16-bit STA OK, second failed
        red ($02) = first failed
        purple ($04) = both failed
    - Infinite loop
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_pbr20_m16.prg')

P2_BASE = 0x0100  # entry within bank $20

# Phase 2 (PBR=$20). Enters with M=X=16 already set by phase 1.
# We assume phase 1 leaves M=X=16 on entry to bank $20.
p2 = bytes([
    # Marker: phase 2 reached. SEP for border write, then back to M=16.
    0xE2, 0x20,                  # SEP #$20 (M=8)
    0xA9, 0x0B,                  # LDA #$0B (gray)
    0x8D, 0x20, 0xD0,            # STA $D020
    0xC2, 0x20,                  # REP #$20 (M=16)
    # Setup zp $50/$51/$52 = $00:$0E0C
    0xA9, 0x0C, 0x0E,            # LDA #$0E0C (16-bit)
    0x85, 0x50,                  # STA $50  (lo+hi as 16-bit)
    0xE2, 0x20,                  # SEP #$20 (M=8)
    0xA9, 0x00,                  # LDA #$00
    0x85, 0x52,                  # STA $52  (bank byte)
    # Switch back to 16-bit M
    0xC2, 0x20,                  # REP #$20 (M=16)
    # Test 1: STA [$50] with 16-bit A = $4342  -> $0E0C=42 $0E0D=43
    0xA9, 0x42, 0x43,            # LDA #$4342
    0x87, 0x50,                  # STA [$50]
    # Test 2: STA [$50],Y with Y=$0002 and 16-bit A=$4544 -> $0E0E=44 $0E0F=45
    0xA0, 0x02, 0x00,            # LDY #$0002
    0xA9, 0x44, 0x45,            # LDA #$4544
    0x97, 0x50,                  # STA [$50],Y
    # Read back via LDA long (8-bit)
    0xE2, 0x20,                  # SEP #$20 (M=8)
    # Default border = purple (both failed)
    0xA9, 0x04,                  # LDA #$04
    0x8D, 0x20, 0xD0,            # STA $D020
    # Read $00:$0E0C, expect $42
    0xAF, 0x0C, 0x0E, 0x00,      # LDA $00:$0E0C (long)
    0xC9, 0x42,                  # CMP #$42
    0xD0, 0x20,                  # BNE +$20 (skip — keep purple)
    0xAF, 0x0D, 0x0E, 0x00,      # LDA $00:$0E0D
    0xC9, 0x43,                  # CMP #$43
    0xD0, 0x18,                  # BNE +$18 (red, first half OK but second byte wrong)
    # First STA OK; default to yellow
    0xA9, 0x07,                  # LDA #$07 (yellow)
    0x8D, 0x20, 0xD0,            # STA $D020
    # Now check second STA at $0E0E/$0E0F
    0xAF, 0x0E, 0x0E, 0x00,      # LDA $00:$0E0E
    0xC9, 0x44,                  # CMP #$44
    0xD0, 0x09,                  # BNE +9 (keep yellow)
    0xAF, 0x0F, 0x0E, 0x00,      # LDA $00:$0E0F
    0xC9, 0x45,                  # CMP #$45
    0xD0, 0x02,                  # BNE +2 (keep yellow)
    # Both passed: green
    0xA9, 0x05,                  # LDA #$05
    0x8D, 0x20, 0xD0,            # STA $D020
    # Infinite loop
    0x4C, 0x00, 0x00,            # JMP abs (placeholder)
    # Red path target (offset $18 from end of CMP #$43 BNE)
    0xA9, 0x02,                  # LDA #$02 (red)
    0x8D, 0x20, 0xD0,            # STA $D020
    0x80, 0xF8,                  # BRA -8 (go to JMP self)
])

# Patch JMP target to point at the JMP itself (infinite loop).
# Find JMP $4C in p2: it's at index where we have 0x4C, 0x00, 0x00.
# It's followed by the red-path code. We need to patch the 2 bytes after $4C.
# Locate: search for 0x4C, 0x00, 0x00 sequence.
jmp_idx = None
for i in range(len(p2) - 2):
    if p2[i] == 0x4C and p2[i+1] == 0x00 and p2[i+2] == 0x00:
        jmp_idx = i
        break
if jmp_idx is None:
    raise SystemExit('JMP placeholder not found')
jmp_addr = P2_BASE + jmp_idx
p2 = p2[:jmp_idx + 1] + bytes([jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF]) + p2[jmp_idx + 3:]

# Phase 1 (runs from bank $00, PBR=$00) — copies p2 to bank $20:P2_BASE
# in M=8 then JMLs to it in M=16 mode.
basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

phase1 = bytes([
    0x78,                            # SEI
    0xD8,                            # CLD
    0x8D, 0x7E, 0xD0,                # STA $D07E
    0x8D, 0x7B, 0xD0,                # STA $D07B
    # Marker phase 1: cyan ($03)
    0xA9, 0x03,
    0x8D, 0x20, 0xD0,
    0x18,                            # CLC
    0xFB,                            # XCE -> native
    # Marker native entered: purple ($04)
    0xA9, 0x04,
    0x8D, 0x20, 0xD0,
    # Setup zp $50..$52 = $20:P2_BASE for the copy loop
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
    # Loop entry:
    0xBD, 0x00, 0x09,                # LDA $0900,X
    0x97, 0x50,                      # STA [$50],Y
    0xE8,                            # INX
    0xC8,                            # INY
    0xC0, len(p2) & 0xFF, (len(p2) >> 8) & 0xFF,  # CPY #len(p2)
    0xD0, 0xF4,                      # BNE -12
    # Marker copy done: light gray ($0F)
    0xA9, 0x0F,
    0x8D, 0x20, 0xD0,
    # Switch to M=16 and JML to bank $20
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
