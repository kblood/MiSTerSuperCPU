#!/usr/bin/env python3
"""Generate decomp_stress.prg

Mimics decompressor patterns: copy 512 bytes from $4000 (the DL bitmap
target) to $4000 via (zp),Y + INC zp pointer-advance, computing a
running XOR checksum. Display the checksum byte at $0400.

If T65 and P65C816 emu produce same checksum, this exact pattern is
clean. If they differ, BRAM RAW hazard or pointer-update timing is
broken in some access mode.

Pattern (the Asterix-class loop):

    LDY #$00
loop:
    LDA ($FB),Y      ; read source via pointer
    EOR checksum     ; mix
    STA checksum
    INY
    BNE loop
    INC $FC          ; advance source page
    DEC pages_left
    BNE loop
"""
import sys

RUNTIME = 0xC000
SRC_PTR = 0xFB        # zp $FB,$FC = source pointer
CHK     = 0xF7        # zp $F7 = checksum
PAGES   = 0xF8        # zp $F8 = pages remaining

# Test data placed at $C400-$C5FF (2 pages, 512 bytes)
DATA_START = 0xC400

code = []
def emit(*bs):
    code.extend(bs)

emit(0x78)                   # SEI
emit(0xD8)                   # CLD
emit(0xA2, 0xFF)             # LDX #$FF
emit(0x9A)                   # TXS

# Setup source ptr = $C400
emit(0xA9, DATA_START & 0xFF)
emit(0x85, SRC_PTR)
emit(0xA9, (DATA_START >> 8) & 0xFF)
emit(0x85, SRC_PTR + 1)

# Init checksum = 0, pages = 2
emit(0xA9, 0x00)
emit(0x85, CHK)
emit(0xA9, 0x02)
emit(0x85, PAGES)

# LDY #$00
emit(0xA0, 0x00)

# loop:
loop_start = len(code)
# LDA ($FB),Y
emit(0xB1, SRC_PTR)
# EOR $F7
emit(0x45, CHK)
# STA $F7
emit(0x85, CHK)
# INY
emit(0xC8)
# BNE loop
back = (loop_start - (len(code) + 2)) & 0xFF
emit(0xD0, back)
# INC $FC (advance page)
emit(0xE6, SRC_PTR + 1)
# DEC $F8
emit(0xC6, PAGES)
# BNE loop
back2 = (loop_start - (len(code) + 2)) & 0xFF
emit(0xD0, back2)

# Display: $0400 = checksum, $0401 = source[0] (control), $0402 = source[1]
emit(0xA5, CHK)              # LDA $F7
emit(0x8D, 0x00, 0x04)       # STA $0400
emit(0xAD, DATA_START & 0xFF, (DATA_START >> 8) & 0xFF)  # LDA $C400
emit(0x8D, 0x01, 0x04)       # STA $0401
emit(0xAD, (DATA_START + 1) & 0xFF, ((DATA_START + 1) >> 8) & 0xFF)  # LDA $C401
emit(0x8D, 0x02, 0x04)       # STA $0402
# Also display source[256] (start of page 2)
emit(0xAD, 0x00, (DATA_START >> 8) + 1)  # LDA $C500
emit(0x8D, 0x03, 0x04)       # STA $0403

# Halt
halt_addr = RUNTIME + len(code)
emit(0x4C, halt_addr & 0xFF, (halt_addr >> 8) & 0xFF)

body_len = len(code)
print(f"; body ends at ${RUNTIME + body_len:04X}", file=sys.stderr)

# Pad to data area at DATA_START
pad = (DATA_START - RUNTIME) - body_len
code.extend([0xEA] * pad)

# Write source pattern: byte i = (i*0x9E + 0x37) & 0xFF (non-cancelling XOR)
def pat(i):
    return (i * 0x9E + 0x37 + (i // 67) * 13) & 0xFF
for i in range(512):
    code.append(pat(i))

# Compute expected checksum
xor = 0
for i in range(512):
    xor ^= pat(i)
print(f"; expected checksum byte at $0400 = ${xor:02X}", file=sys.stderr)

# BASIC stub
basic_stub = bytes([
    0x0C, 0x08, 0x0A, 0x00, 0x9E,
    0x34, 0x39, 0x31, 0x35, 0x32,
    0x00, 0x00, 0x00,
])
load_addr = 0x0801
gap = RUNTIME - (load_addr + len(basic_stub))
content = bytearray(basic_stub) + bytearray([0x00] * gap) + bytearray(code)
prg = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + bytes(content)

with open("tools/decomp_stress.prg", "wb") as f:
    f.write(prg)
print(f"; wrote tools/decomp_stress.prg ({len(prg)} bytes)", file=sys.stderr)
