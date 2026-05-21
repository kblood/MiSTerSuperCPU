#!/usr/bin/env python3
"""Generate peek_bank01_6c00.prg — reads SuperRAM $01:$6C00/$6C03/$6C05
and lets the v282 UART latches capture the cpuDi values.

Loaded via MGL AFTER Doom has run + populated SDRAM. SDRAM survives
core reload so bank $01 contents persist.

Layout:
  $0801: BASIC SYS 2061 stub
  $080D: probe code
"""
import os, struct

prg = bytearray()
# Load address $0801
prg += struct.pack('<H', 0x0801)
# BASIC line: 10 SYS 2061
basic = bytearray()
# Pointer to next line — fixup later
basic += b'\x0B\x08'
# Line number 10
basic += b'\x0A\x00'
# SYS token + ASCII "2061" + null
basic += b'\x9E' + b'2061' + b'\x00'
# End of BASIC: zero pointer
basic += b'\x00\x00'
prg += basic
# Pad to $080D (file offset 2 + 0x0C = 0x0E; we need code at $080D = file offset 2 + 0x0C)
# Currently at file_offset 2 + len(basic) = 2 + 0x0C = 0x0E (= $080D). Good.

# Probe code at $080D
code = bytearray([
    0x78,                           # SEI
    0xA9, 0x35, 0x85, 0x01,         # LDA #$35; STA $01  (bank out KERNAL)
    0xA9, 0x80,                     # LDA #$80
    0x8D, 0x7E, 0xD0,               # STA $D07E  (SCPU enable)
    0x8D, 0x7B, 0xD0,               # STA $D07B  (20MHz)
    0x18,                           # CLC
    0xFB,                           # XCE — switch to native mode
    0xC2, 0x30,                     # REP #$30 — 16-bit M and X
    # Loop reading $01:$6C00/$03/$05 forever to feed UART latches
    # Loop label = $0820 (computed below)
])
# Loop body at $0820:
loop_addr = 0x0820
# Compute current addr after code
cur_addr = 0x080D + len(code)
# Pad NOPs to $0820
while cur_addr < loop_addr:
    code.append(0xEA)  # NOP
    cur_addr += 1

# Loop body: LDA long, then JMP loop
code += bytearray([
    0xAF, 0x00, 0x6C, 0x01,         # LDA $01:$6C00 (long)
    0xAF, 0x03, 0x6C, 0x01,         # LDA $01:$6C03
    0xAF, 0x05, 0x6C, 0x01,         # LDA $01:$6C05
    # Also touch $00:$6C03 to keep B field updated as reference
    0xAF, 0x03, 0x6C, 0x00,         # LDA $00:$6C03
    # JMP back to loop
    0x4C, loop_addr & 0xFF, (loop_addr >> 8) & 0xFF,
])

prg += code

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_bank01_6c00.prg')
with open(out_path, 'wb') as f:
    f.write(prg)
print(f'Wrote {out_path}: {len(prg)} bytes')
print(f'Code starts at $080D, loop at ${loop_addr:04X}')
print(f'Last code byte at ${0x0801 + len(prg) - 1:04X}')
