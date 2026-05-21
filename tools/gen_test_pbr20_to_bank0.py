#!/usr/bin/env python3
"""Generate test_pbr20_to_bank0.prg — exercise STA [zp],Y to bank $00 from PBR=$20.

Doom's bug pattern: it runs from bank $20 (PBR=$20 after loader JML) and
expects STA [$50],Y with $52=$00 to write to c64 RAM bank $00. The simple
test PBR=$00 -> bank $00 long-store works (green-border test passed).
This test runs the same opcode but from PBR=$20.

Plan:
  Phase 1 (PBR=$00):
    - Enable SCPU + turbo, native mode, REP #$30
    - Copy a small payload (~30 bytes) into bank $20 SuperRAM via STA long
    - JML to bank $20 entry
  Phase 2 (PBR=$20):
    - Set up zp $50/$51/$52 = $00:$0E0C
    - LDA #$42 ; STA [$50] -> $00:$0E0C
    - LDY #$0001 ; LDA #$43 ; STA [$50],Y -> $00:$0E0D
    - Compare results, set $D020 border:
        green ($05) = both writes landed
        yellow ($07) = only first landed
        red ($02)   = neither landed (BUG)
    - Infinite loop
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'test_pbr20_to_bank0.prg')

# Phase 2 payload (runs from bank $20). We assemble it for entry $20:0100.
# Choose $0100 because page 0 of bank $20 is fine; first 256 bytes of bank $20
# might overlap with Doom code if any was left, but after a fresh boot bank
# $20 SDRAM is presumed zero/random. Use $0100 to be safe of zero-page-like
# semantics.
P2_BASE = 0x0100  # entry within bank $20
p2 = bytes([
    # MARKER: phase 2 reached. Set border = $0B (gray) before any test.
    0xE2, 0x20,              # SEP #$20 (M=8) — needed for 8-bit STA
    0xA9, 0x0B,              # LDA #$0B
    0x8D, 0x20, 0xD0,        # STA $D020
    0xC2, 0x20,              # REP #$20 (M=16 again)
    # Setup zp pointer $50/$51/$52 = $00:$0E0C
    # We're in 16-bit M and X mode (REP #$30 done in phase 1).
    0xA9, 0x0C, 0x0E,        # LDA #$0E0C (16-bit)
    0x85, 0x50,              # STA $50  (lo+hi)
    0xE2, 0x20,              # SEP #$20 (M=8)
    0xA9, 0x00,              # LDA #$00
    0x85, 0x52,              # STA $52  (bank byte)
    # Test 1: STA [$50] -> $00:$0E0C
    0xA9, 0x42,              # LDA #$42
    0x87, 0x50,              # STA [$50]
    # Test 2: STA [$50],Y -> $00:$0E0D
    0xC2, 0x10,              # REP #$10 (X=16)
    0xA0, 0x01, 0x00,        # LDY #$0001
    0xE2, 0x10,              # SEP #$10 (X=8)
    0xA9, 0x43,              # LDA #$43
    0x97, 0x50,              # STA [$50],Y
    # Decide border color
    0xA9, 0x02,              # LDA #$02 (red default)
    0x8D, 0x20, 0xD0,        # STA $D020
    # Read back via long absolute (PBR=$20 but ABS uses DBR; default DBR=0)
    # To be safe, use long absolute STA: $AF = LDA long
    0xAF, 0x0C, 0x0E, 0x00,  # LDA $00:$0E0C (long)
    0xC9, 0x42,              # CMP #$42
    0xD0, 0x10,              # BNE +16 (skip green/yellow)
    0xAF, 0x0D, 0x0E, 0x00,  # LDA $00:$0E0D (long)
    0xC9, 0x43,              # CMP #$43
    0xD0, 0x07,              # BNE +7 (yellow-only path)
    # Both passed: green
    0xA9, 0x05,              # LDA #$05
    0x8D, 0x20, 0xD0,        # STA $D020
    0x80, 0x05,              # BRA +5
    # Yellow: only first store landed
    0xA9, 0x07,              # LDA #$07
    0x8D, 0x20, 0xD0,        # STA $D020
    # Infinite loop
    # JMP abs - target = PC of this JMP; we patch at end.
    0x4C,                    # JMP abs
    0x00, 0x00,              # placeholder JMP target
])
# Patch the JMP target to point back to itself.
# JMP byte is at offset (len(p2)-3) within bank $20 entry P2_BASE.
jmp_offset = len(p2) - 3
jmp_addr_in_bank20 = P2_BASE + jmp_offset
p2 = p2[:-2] + bytes([jmp_addr_in_bank20 & 0xFF, (jmp_addr_in_bank20 >> 8) & 0xFF])

# Phase 1 (runs from bank $00, PBR=$00) — copies p2 to bank $20:P2_BASE
# and JMLs to it.
phase1_addr = 0x080D
basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

# Phase 1 code:
#   SEI ; CLD
#   STA $D07E ; STA $D07B            ; SCPU enable + turbo
#   CLC ; XCE                        ; emul -> native
#   REP #$30                         ; M=0, X=0
#   ; Copy p2 from $0900 (we'll embed payload at $0900 in bank 0) to $20:P2_BASE
#   ; Use MVP/MVN block move. MVN: $54 dst-bank src-bank
#   ;   moves from src=src-bank:X to dst=dst-bank:Y, length A+1.
#   LDX #$0900 (16-bit imm)          ; X = source 16-bit addr
#   LDY #P2_BASE (16-bit)            ; Y = dest 16-bit addr
#   LDA #(len(p2)-1)                 ; A = count - 1
#   MVN $20, $00 ; opcode $54 dst-bank src-bank
#   ; Now JML $20:P2_BASE
#   JML $20:P2_BASE                  ; opcode $5C lo mid bank
phase1 = bytes([
    0x78,                            # SEI
    0xD8,                            # CLD
    0x8D, 0x7E, 0xD0,                # STA $D07E
    0x8D, 0x7B, 0xD0,                # STA $D07B
    # MARKER: phase 1 reached. Border = $03 (cyan). 8-bit M is still in effect.
    0xA9, 0x03,                      # LDA #$03
    0x8D, 0x20, 0xD0,                # STA $D020
    0x18,                            # CLC
    0xFB,                            # XCE
    # MARKER: native mode entered. Border = $04 (purple).
    0xA9, 0x04,                      # LDA #$04
    0x8D, 0x20, 0xD0,                # STA $D020
    # Skip MVN — copy via STA long byte-by-byte using X as the source/dest offset.
    # Setup zp $52 = $20 (dest bank), $50/$51 = P2_BASE.
    0xE2, 0x20,                      # SEP #$20 (M=8)
    0xA9, P2_BASE & 0xFF,            # LDA #lo(P2_BASE)
    0x85, 0x50,                      # STA $50
    0xA9, (P2_BASE >> 8) & 0xFF,     # LDA #hi(P2_BASE)
    0x85, 0x51,                      # STA $51
    0xA9, 0x20,                      # LDA #$20
    0x85, 0x52,                      # STA $52
    # Copy len(p2) bytes from $0900,X to [$50],Y where X=Y go 0..len-1
    0xC2, 0x10,                      # REP #$10 (X=Y=16)
    0xA2, 0x00, 0x00,                # LDX #$0000
    0xA0, 0x00, 0x00,                # LDY #$0000
    # Loop:
    0xBD, 0x00, 0x09,                # LDA $0900,X (8-bit M)
    0x97, 0x50,                      # STA [$50],Y
    0xE8,                            # INX
    0xC8,                            # INY
    0xC0, len(p2) & 0xFF, (len(p2) >> 8) & 0xFF,  # CPY #len(p2) (16-bit)
    0xD0, 0xF4,                      # BNE -12 (back to LDA $0900,X)
    # MARKER: copy finished. Border = $0F.
    0xA9, 0x0F,                      # LDA #$0F
    0x8D, 0x20, 0xD0,                # STA $D020
    # JML $20:P2_BASE
    0x5C, P2_BASE & 0xFF, (P2_BASE >> 8) & 0xFF, 0x20,
])

# Layout: $0801..$080C BASIC stub. $080D phase1. Pad to $0900 then payload p2.
# The MVN copies from $0900 (in bank 0) to $20:P2_BASE.
PAD_TO = 0x0900  # absolute mem addr where payload starts
phase1_end = phase1_addr + len(phase1)
pad_bytes = PAD_TO - phase1_end
if pad_bytes < 0:
    raise SystemExit('phase1 too long, won\'t fit before $0900')
print(f'phase1 size={len(phase1)}, ends at ${phase1_end:04X}, pad {pad_bytes} bytes -> ${PAD_TO:04X}')
print(f'phase2 size={len(p2)}')

prg = bytes([0x01, 0x08]) + basic_stub + phase1 + bytes(pad_bytes) + p2
with open(OUT, 'wb') as f:
    f.write(prg)
print(f'wrote {OUT} ({len(prg)} bytes)')
