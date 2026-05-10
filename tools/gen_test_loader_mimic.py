#!/usr/bin/env python3
"""Mimic the EXACT Doom loader pattern for two banks.

For BANK1 ($28) and BANK2 ($2A):
  Iteration:
    STA $D07A (1MHz)           ; outer-iteration prefix
    FETCH directory (no-op for our test, but read from REU)
    For one page only:
      FETCH from REU bank:00 -> $0500 (in 1MHz)
      STA $D07B (turbo)
      Long-store $0500..$05FF -> bank:6C00
      STA $D07A (1MHz)

Then native + 16-bit M, LDA long $2A:$6C00. Border green if = $3E.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_loader_mimic.prg')

basic_stub = bytes([
    0x0B, 0x08, 0x0A, 0x00, 0x9E,
    0x32, 0x30, 0x36, 0x31,
    0x00, 0x00, 0x00,
])

code = []
def emit(*bs): code.extend(bs)

emit(0x78)                           # SEI
emit(0xA9, 0x35, 0x85, 0x01)
emit(0x8D, 0x7E, 0xD0)               # SCPU regs en
emit(0x8D, 0x7A, 0xD0)               # 1MHz mode (initial)

emit(0xA9, 0x03, 0x8D, 0x20, 0xD0)   # border cyan

def emit_iteration(bank):
    # FETCH REU bank:6C:00 -> c64 $0500, len 256 (in 1MHz)
    emit(0xA9, 0x00, 0x8D, 0x02, 0xDF)   # c64 lo
    emit(0xA9, 0x05, 0x8D, 0x03, 0xDF)   # c64 hi = $05
    emit(0xA9, 0x00, 0x8D, 0x04, 0xDF)   # REU lo = 0
    emit(0xA9, 0x6C, 0x8D, 0x05, 0xDF)   # REU mid = $6C
    emit(0xA9, bank, 0x8D, 0x06, 0xDF)   # REU hi = bank
    emit(0xA9, 0x00, 0x8D, 0x07, 0xDF)   # len lo
    emit(0xA9, 0x01, 0x8D, 0x08, 0xDF)   # len hi (256)
    emit(0xA9, 0x91, 0x8D, 0x01, 0xDF)   # FETCH cmd
    # Turbo on for long-store
    emit(0x8D, 0x7B, 0xD0)
    # Long-store
    emit(0xA9, 0x00, 0x85, 0xFB)
    emit(0xA9, 0x6C, 0x85, 0xFC)
    emit(0xA9, bank, 0x85, 0xFD)
    emit(0xA9, 0x34, 0x85, 0x01)
    emit(0xA0, 0x00)
    emit(0xB9, 0x00, 0x05)
    emit(0x97, 0xFB)
    emit(0xC8)
    emit(0xD0, 0xF8)
    emit(0xA9, 0x35, 0x85, 0x01)
    # 1MHz on (mimics Doom inner-end)
    emit(0x8D, 0x7A, 0xD0)

# Iteration for bank $28 (warm up the toggle pattern)
emit_iteration(0x28)
# Iteration for bank $2A (the one we'll verify)
emit_iteration(0x2A)

# Now CHECK bank $2A:$6C00 (this is in 1MHz mode)
# Need turbo on for SCPU long-load (16-bit)
emit(0x8D, 0x7B, 0xD0)               # turbo on
emit(0x18, 0xFB)                     # CLC; XCE -> native
emit(0xC2, 0x20)                     # REP #$20
emit(0xAF, 0x00, 0x6C, 0x2A)         # LDA $2A:6C00
emit(0xE2, 0x20)                     # SEP #$20

emit(0xC9, 0x3E)                     # CMP #$3E
bne_pos = len(code)
emit(0xD0, 0x00)

emit(0xA9, 0x05, 0x8D, 0x20, 0xD0)   # green
pass_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)

red_pos = len(code)
emit(0xA9, 0x02, 0x8D, 0x20, 0xD0)   # red
fail_jmp_pos = len(code)
emit(0x4C, 0x00, 0x00)

bne_offset = red_pos - (bne_pos + 2)
assert -128 <= bne_offset <= 127
code[bne_pos + 1] = bne_offset & 0xFF

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
