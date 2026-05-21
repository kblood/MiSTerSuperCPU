#!/usr/bin/env python3
"""Long-store-only test (NO REU). Writes $3E to bank $2A:$6C00 via STA [$FB],
then reads back via LDA long $2A:$6C00. Border green if readback = $3E.

Isolates whether long-store + long-load to SuperRAM bank $2A works on
v277 hardware.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_long_store_only.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

code = []
def emit(*bs): code.extend(bs)

# Cyan border so we know code reached this point
emit(0x78)                           # SEI
emit(0xA9, 0x35, 0x85, 0x01)         # $01 = $35 (RAM at $E000)
emit(0x8D, 0x7E, 0xD0)               # SCPU regs en
emit(0x8D, 0x7A, 0xD0)
emit(0x8D, 0x7B, 0xD0)               # turbo
emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # border cyan

# Set $FB/$FC/$FD = $2A:$6C00 (long pointer)
emit(0xA9, 0x00, 0x85, 0xFB)
emit(0xA9, 0x6C, 0x85, 0xFC)
emit(0xA9, 0x2A, 0x85, 0xFD)

# A = $3E, Y=0, STA [$FB],Y -> bank $2A:$6C00
emit(0xA9, 0x3E)                     # LDA #$3E
emit(0xA0, 0x00)                     # LDY #$00
emit(0x97, 0xFB)                     # STA [$FB],Y

# Native + 16-bit M for LDA long
emit(0x18, 0xFB)                     # CLC; XCE
emit(0xC2, 0x20)                     # REP #$20

# LDA long $2A:$6C00 (16-bit M reads $6C00..$6C01)
emit(0xAF, 0x00, 0x6C, 0x2A)         # LDA $2A:6C00

# Save A_low to D000 (border) via SEP first
emit(0xE2, 0x20)                     # SEP #$20 (back to 8-bit)

# Compare A with $3E
emit(0xC9, 0x3E)                     # CMP #$3E
bne_pos = len(code)
emit(0xD0, 0x00)                     # BNE +? placeholder

# PASS: green border
emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)
pass_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)               # JMP self

# RED label
red_pos = len(code)
emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)
fail_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)

# Patch BNE
bne_offset = red_pos - (bne_pos + 2)
assert -128 <= bne_offset <= 127
code[bne_pos + 1] = bne_offset & 0xFF

# Patch JMP self
addr = 0x080D + pass_jmp_pos
code[pass_jmp_pos + 1] = addr & 0xFF
code[pass_jmp_pos + 2] = (addr >> 8) & 0xFF
addr = 0x080D + fail_jmp_pos
code[fail_jmp_pos + 1] = addr & 0xFF
code[fail_jmp_pos + 2] = (addr >> 8) & 0xFF

prg = bytes([0x01, 0x08]) + basic_stub + bytes(code)
with open(OUT, 'wb') as f:
    f.write(prg)
print('wrote {} ({} bytes)'.format(OUT, len(prg)))
