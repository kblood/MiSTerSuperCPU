#!/usr/bin/env python3
"""Simulate Doom loader's exact REU-FETCH-then-long-store sequence.

Path: REU $2A:$6C00 -> c64 $0500 (FETCH 256 bytes)
      -> long-store $0500..$05FF to long [$FB] = bank $2A:$6C00
      -> LDA long $2A:$6C00 (READ-BACK; triggers v277 mem_44 latch on $2A:$6C00)
      -> set border = green ($05) on PASS, red ($02) on FAIL

The READ-BACK at LDA long $2A:$6C00 ALSO updates the v277 mem_44 latch with
the current byte value. Hardware UART will reveal whether bank $2A:$6C00
got correctly populated or not.

Border green = readback returned $3E, red = something else.
Cyan = code stuck mid-execution (didn't reach border instruction).
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_loader_chain.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

# Build code with manual label tracking
code = []
def emit(*bs): code.extend(bs)

# SEI; setup
emit(0x78)
emit(0xA9, 0x35, 0x85, 0x01)
emit(0x8D, 0x7E, 0xD0)               # SCPU regs en
emit(0x8D, 0x7A, 0xD0)
emit(0x8D, 0x7B, 0xD0)               # turbo
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # border cyan

# REU FETCH from $2A:$6C00 -> $0500
emit(0xA9, 0x00, 0x8D, 0x02, 0xDF)   # c64 lo
emit(0xA9, 0x05, 0x8D, 0x03, 0xDF)   # c64 hi
emit(0xA9, 0x00, 0x8D, 0x04, 0xDF)   # REU lo
emit(0xA9, 0x6C, 0x8D, 0x05, 0xDF)   # REU mid
emit(0xA9, 0x2A, 0x8D, 0x06, 0xDF)   # REU hi
emit(0xA9, 0x00, 0x8D, 0x07, 0xDF)   # len lo
emit(0xA9, 0x01, 0x8D, 0x08, 0xDF)   # len hi (256)
emit(0xA9, 0x91, 0x8D, 0x01, 0xDF)   # FETCH cmd

# Long-store $0500 -> bank $2A:$6C00 via [$FB]
emit(0xA9, 0x00, 0x85, 0xFB)
emit(0xA9, 0x6C, 0x85, 0xFC)
emit(0xA9, 0x2A, 0x85, 0xFD)
emit(0xA9, 0x34, 0x85, 0x01)         # RAM at $E000
emit(0xA0, 0x00)                     # LDY #$00
emit(0xB9, 0x00, 0x05)               # loop: LDA $0500,Y
emit(0x97, 0xFB)                     # STA [$FB],Y
emit(0xC8)                           # INY
emit(0xD0, 0xF8)                     # BNE -8 (back to LDA)
emit(0xA9, 0x35, 0x85, 0x01)         # restore $01

# Native + 16-bit M
emit(0x18, 0xFB)                     # CLC; XCE
emit(0xC2, 0x20)                     # REP #$20

# LDA long $2A:$6C00 (should be $3E if all worked)
emit(0xAF, 0x00, 0x6C, 0x2A)         # LDA $2A:6C00 (16-bit M -> reads $6C00 + $6C01)

# Save offset before branch
cmp_pos = len(code)
emit(0xC9, 0x3E, 0x00)               # CMP #$003E
# BNE forward to RED — patch later
bne_pos = len(code)
emit(0xD0, 0x00)                     # BNE +? (placeholder)

# PASS: SEP, border green, JMP self
emit(0xE2, 0x20)
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)
pass_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)               # JMP self placeholder

# RED label
red_pos = len(code)
emit(0xE2, 0x20)
emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)
fail_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)

# Patch BNE: target = red_pos, current = bne_pos+2 (after BNE inst)
bne_offset = red_pos - (bne_pos + 2)
assert -128 <= bne_offset <= 127, "BNE offset out of range: " + str(bne_offset)
code[bne_pos + 1] = bne_offset & 0xFF

# Patch JMP self for PASS
addr = 0x080D + pass_jmp_pos
code[pass_jmp_pos + 1] = addr & 0xFF
code[pass_jmp_pos + 2] = (addr >> 8) & 0xFF
addr = 0x080D + fail_jmp_pos
code[fail_jmp_pos + 1] = addr & 0xFF
code[fail_jmp_pos + 2] = (addr >> 8) & 0xFF

prg = bytes([0x01, 0x08]) + basic_stub + bytes(code)
with open(OUT, 'wb') as f:
    f.write(prg)
print('wrote {} ({} bytes), code_len={}, BNE off={}'.format(OUT, len(prg), len(code), bne_offset))
