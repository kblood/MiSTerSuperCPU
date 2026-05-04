#!/usr/bin/env python3
"""Generate test_long_store_bank0.prg — minimal SCPU long-store sanity check.

Code at $080D:
  SEI ; CLD
  STA $D07E ; STA $D07B           ; SCPU enable + turbo
  CLC ; XCE                       ; emul -> native (M=X=8 in native)
  REP #$30                        ; M=0, X=0 (16-bit)
  LDA #$0E0C ; STA $50            ; long ptr lo/hi at zp
  SEP #$20                        ; M=1 (8-bit)
  LDA #$00 ; STA $52              ; bank byte = $00
  LDA #$42 ; STA [$50]            ; long-store: $00:$0E0C = $42
  REP #$10
  LDY #$0001
  SEP #$10
  LDA #$43 ; STA [$50],Y          ; long-store: $00:$0E0D = $43
  LDA $0E0C ; STA $0400           ; copy to screen for visual check
  LDA $0E0D ; STA $0401
  SEC ; XCE                       ; back to emulation
  STA $D07F                       ; disable SCPU regs
  CLI ; RTS                       ; return to BASIC

After PRG runs, screen top-left two cells should show $42 $43 = '*' '+' in
PETSCII screen-codes. If they show $00 $00 (or random) the long-store path
is broken.
"""
import os, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_long_store_bank0.prg')

# BASIC stub: 10 SYS 2061
basic_stub = bytes([
    0x0B, 0x08,                         # next line ptr = $080B
    0x0A, 0x00,                         # line 10
    0x9E,                               # SYS token
    0x32, 0x30, 0x36, 0x31,             # "2061"
    0x00,                               # end of line
    0x00, 0x00,                         # end of program
])

# Code at $080D — uses border color + infinite loop so result survives.
# Border color decision tree:
#   $0E0C == $42 AND $0E0D == $43 -> border = $05 (GREEN)  : both stores OK
#   $0E0C == $42 AND $0E0D != $43 -> border = $07 (YELLOW) : STA [$50]   OK, STA [$50],Y FAIL
#   $0E0C != $42 AND $0E0D == $43 -> border = $0E (LBLUE)  : STA [$50]   FAIL, STA [$50],Y OK (unlikely)
#   neither matches              -> border = $02 (RED)    : both fail (= long-store path broken)
code = bytes([
    0x78,                               # SEI
    0xD8,                               # CLD
    0x8D, 0x7E, 0xD0,                   # STA $D07E   (SCPU hwenable+regs)
    0x8D, 0x7B, 0xD0,                   # STA $D07B   (turbo)
    0x18,                               # CLC
    0xFB,                               # XCE         (emul -> native)
    0xC2, 0x30,                         # REP #$30    (M=0, X=0)
    0xA9, 0x0C, 0x0E,                   # LDA #$0E0C  (16-bit imm)
    0x85, 0x50,                         # STA $50
    0xE2, 0x20,                         # SEP #$20    (M=1)
    0xA9, 0x00,                         # LDA #$00
    0x85, 0x52,                         # STA $52     (bank byte)
    0xA9, 0x42,                         # LDA #$42
    0x87, 0x50,                         # STA [$50]               -> $00:$0E0C = $42
    0xC2, 0x10,                         # REP #$10    (X=0)
    0xA0, 0x01, 0x00,                   # LDY #$0001
    0xE2, 0x10,                         # SEP #$10    (X=1)
    0xA9, 0x43,                         # LDA #$43
    0x97, 0x50,                         # STA [$50],Y             -> $00:$0E0D = $43
    # Decide border color based on what made it into bank $00 RAM
    0xA9, 0x02,                         # LDA #$02 (red default)
    0x8D, 0x20, 0xD0,                   # STA $D020
    0xAD, 0x0C, 0x0E,                   # LDA $0E0C
    0xC9, 0x42,                         # CMP #$42
    0xD0, 0x0D,                         # BNE +13 (skip green-path)
    0xAD, 0x0D, 0x0E,                   # LDA $0E0D
    0xC9, 0x43,                         # CMP #$43
    0xD0, 0x06,                         # BNE +6 (skip green)
    0xA9, 0x05,                         # LDA #$05 (green)
    0x8D, 0x20, 0xD0,                   # STA $D020
    0x80, 0x05,                         # BRA +5
    # yellow path (only first store succeeded)
    0xA9, 0x07,                         # LDA #$07 (yellow)
    0x8D, 0x20, 0xD0,                   # STA $D020
    # Also paint screen RAM $0400 with the actual bytes we read
    0xAD, 0x0C, 0x0E,                   # LDA $0E0C
    0x8D, 0x00, 0x04,                   # STA $0400
    0xAD, 0x0D, 0x0E,                   # LDA $0E0D
    0x8D, 0x01, 0x04,                   # STA $0401
    # Infinite loop so BASIC READY scroll can't overwrite the result
    0x4C,                               # JMP abs (next 2 bytes = current addr)
    # JMP target = $ here. We'll patch after assembly; for now emit a
    # forward branch that loops to itself.
    0x00, 0x00,                         # placeholder for JMP target
])

# Patch the JMP target to point back to itself (-3 from end = JMP at end-3)
# Actually, the JMP $xxxx three bytes are at offset (len-3, len-2, len-1).
# We want: at addr X = $080D + (len-3), JMP X.
jmp_addr = 0x080D + len(code) - 3
code = code[:-2] + bytes([jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF])

prg = bytes([0x01, 0x08]) + basic_stub + code
with open(OUT, 'wb') as f:
    f.write(prg)
print(f'wrote {OUT} ({len(prg)} bytes)')
print(f'code_size={len(code)}, end addr=${0x080D + len(code) - 1:04X}')
