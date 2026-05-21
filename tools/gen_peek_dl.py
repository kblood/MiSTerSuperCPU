#!/usr/bin/env python3
"""Peek bytes from $3100-$321F and display as hex on screen.

Loaded after DL has run. C64 reset preserves bank-0 SDRAM contents
(per CLAUDE.md), so $3100/$3200 IRQ-handler bytes should still be
intact at peek time. Layout:

  Row 0 (\$0400-\$0413): "3108: XX XX XX ..."
  Row 1 (\$0428-\$043B): "3128: XX XX XX ..."
  Row 2 (\$0450-\$0463): "3208: XX XX XX ..."
  Row 3 (\$0478-\$048B): "3228: XX XX XX ..."

Each row dumps 8 bytes from the named address, formatted as 2-digit hex.
"""
import sys

RUNTIME = 0xC000

code = []
def emit(*bs):
    code.extend(bs)

emit(0x78)               # SEI
emit(0xD8)               # CLD
emit(0xA2, 0xFF)         # LDX #$FF
emit(0x9A)               # TXS

# Helper: byte-to-2-hex on screen at $0400+offset
# Routine at $C200: takes byte in A, writes 2 chars to $0400+X (X=offset)
# Then increments X by 3 (2 chars + 1 space)
# X is preserved across calls.

# Assume X=screen offset

# Inline 8-byte hex dump: src=ptr in $FB/$FC, base offset in Y for screen base
# We will inline 4 hex dumps, each writing 8 hex pairs.
def dump_hex_pair(src_lo, src_hi, screen_off):
    # LDA src,Y / split to 2 hex chars / STA $0400+screen_off+0..1 / inc screen offset
    pass

# Simpler: write a tight subroutine to convert A → 2 chars
# Routine at $C100:
#   PHA / LSR / LSR / LSR / LSR / JSR nibble / PLA / AND #$0F / JMP nibble
# nibble: CMP #$0A / BCC digit / ADC #$06 / digit: ADC #$30 / RTS — then char goes to $0400,X (X-managed by caller)
# Too complex. Do it inline.

# Pre-compute the full output: 4 lines x 24 chars
# We'll loop 8 bytes from each base, converting each via JSR.

# At $C100 — dispatch routine:
# byte_to_screen: input A=byte to format, X=screen offset
# Writes 2 chars at $0400+X, $0401+X. Returns with X+=3.
# Pseudocode:
#   PHA (save full byte)
#   LSR LSR LSR LSR (high nibble)
#   CMP #$0A / BCC + / ADC #$06 / ADC #$30 — 6 cycles; produces ASCII '0'-'9' or 'A'-'F' minus 1 needs SEC fudge
# Use pre-computed nibble table at $C300 (16 bytes 30..39, 41..46)

# Build nibble table at $C300 (16 bytes)
# We'll embed it inline.

# Body emitter
emit(0xA2, 0x00)          # LDX #$00 (screen offset)

# 4 rows; for each row:
#   Y=0: copy 8 bytes from base addr, output as hex
#   row 0: src = $3100 (offset 8 = $3108)
#   row 1: src = $3120 (offset 8 = $3128)  -- skip
#   actually let's just dump $3100-$311F (32 bytes / 4 rows of 8)
#   and $3200-$321F (32 bytes / 4 rows of 8)

# Setup nibble table at $C300 dynamically below

# Dump loop: for each base [$3100, $3120, $3200, $3220]:
#   Y=0
# loop:
#   LDA (src),Y
#   high nibble -> $C300+nibble -> store at $0400+X
#   low nibble  -> $C300+nibble -> store at $0401+X
#   X += 3
#   Y++ until Y=8
#   Then advance X to next screen line ($0400+40=$0428)

# Setup self-modifying code addresses
def make_dump(base_addr, screen_base):
    # store base_addr in $FB/$FC
    emit(0xA9, base_addr & 0xFF)
    emit(0x85, 0xFB)
    emit(0xA9, (base_addr >> 8) & 0xFF)
    emit(0x85, 0xFC)
    # X is screen offset; reset to fresh
    # Set X = screen_base - 0x0400 (so STA $0400,X writes at screen_base)
    off = screen_base - 0x0400
    emit(0xA2, off & 0xFF)  # LDX #imm (off is < 256 for our chosen positions)
    # Y = 0
    emit(0xA0, 0x00)
    # Inner loop, runs Y=0..7 (8 iterations)
    loop_pc = len(code)
    # LDA ($FB),Y
    emit(0xB1, 0xFB)
    # save A in $FD
    emit(0x85, 0xFD)
    # high nibble -> A
    emit(0x4A)            # LSR
    emit(0x4A)            # LSR
    emit(0x4A)            # LSR
    emit(0x4A)            # LSR
    # convert A to PETSCII via lookup table at $C300
    emit(0xAA)            # TAX (use X as table index)
    emit(0xBD, 0x00, 0xC8)  # LDA $C300,X
    # restore X to screen offset (we trashed it)
    # ugh — we need to manage X better. Let me use $FE for screen offset.
    pass

# Let me restart with cleaner register allocation:
# Y = byte index (0..7), used for source LDA
# $FE = screen offset (0..23), incremented by 3 per byte
# X = scratch for nibble lookup
code.clear()
emit(0x78)
emit(0xD8)
emit(0xA2, 0xFF); emit(0x9A)

# Build nibble table at $C300 below

# For each (src_addr, screen_base) tuple, emit a dump block
DUMPS = [
    (0x3100, 0x0400),  # row 0
    (0x3120, 0x0428),  # row 1
    (0x3200, 0x0450),  # row 2
    (0x3220, 0x0478),  # row 3
]

# Macro: emit dump
for src, scr in DUMPS:
    # FB,FC = src ptr
    emit(0xA9, src & 0xFF); emit(0x85, 0xFB)
    emit(0xA9, (src >> 8) & 0xFF); emit(0x85, 0xFC)
    # FE = screen offset = scr - $0400
    off = scr - 0x0400
    emit(0xA9, off & 0xFF); emit(0x85, 0xFE)
    # Y = 0
    emit(0xA0, 0x00)
    # loop:
    loop_start = len(code)
    # LDA (FB),Y
    emit(0xB1, 0xFB)
    # save full byte into $FD
    emit(0x85, 0xFD)
    # high nibble
    emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
    # X = A
    emit(0xAA)
    # A = $C300,X (PETSCII char)
    emit(0xBD, 0x00, 0xC8)
    # Store at $0400,Y_disp ... we need Y free for byte index. Use absolute,X-style instead.
    # Actually we need: write to ($0400 + $FE), where $FE is screen offset.
    # Use STA ($1B),Y form? Don't have. Use indirect through $1A/$1B.
    # Pre-set $1A,$1B = $0400 (only once per dump):
    pass

# I'm complicating this. Let me restart with a simpler strategy:
# Just unroll 64 byte reads (32 from $3100, 32 from $3200) and 64 STAs
# to specific screen positions. No loops. Big PRG (~1KB) but easy.

code.clear()
emit(0x78); emit(0xD8); emit(0xA2, 0xFF); emit(0x9A)

# Nibble table at $C300: write it out first
# Place at $C300 via emit...EA padding
# PETSCII codes for digits 0-9 = $30-$39, A-F = $41-$46
NIBBLE = [0x30+i for i in range(10)] + [0x41+i for i in range(6)]

# Helper: emit LDA $base,X / convert / store at screen+pos*3, screen+pos*3+1
# X-as-iterator approach:
def hex_dump_block(src_addr, screen_base, count):
    """Emit code that dumps `count` bytes from src_addr to screen_base
    (3 chars per byte: hi-nibble, lo-nibble, space)."""
    for i in range(count):
        src = src_addr + i
        scr = screen_base + i * 3
        # LDA $src
        emit(0xAD, src & 0xFF, (src >> 8) & 0xFF)
        # save in $FD
        emit(0x85, 0xFD)
        # high nibble
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
        # X = A
        emit(0xAA)
        # A = $C300,X
        emit(0xBD, 0x00, 0xC8)
        # STA scr+0
        emit(0x8D, scr & 0xFF, (scr >> 8) & 0xFF)
        # restore byte from $FD
        emit(0xA5, 0xFD)
        # low nibble: AND #$0F
        emit(0x29, 0x0F)
        # X = A
        emit(0xAA)
        # A = $C300,X
        emit(0xBD, 0x00, 0xC8)
        # STA scr+1
        emit(0x8D, (scr+1) & 0xFF, ((scr+1) >> 8) & 0xFF)

# Dump 8 bytes each from 4 starting points
for src, scr in [(0x3100, 0x0400), (0x3120, 0x0428), (0x3200, 0x0450), (0x3220, 0x0478)]:
    hex_dump_block(src, scr, 8)

# halt
halt = RUNTIME + len(code)
emit(0x4C, halt & 0xFF, (halt >> 8) & 0xFF)

body_len = len(code)
print(f'; body ends at ${RUNTIME + body_len:04X}', file=sys.stderr)

# Pad to $C300
pad = (0xC800 - RUNTIME) - body_len
if pad < 0:
    print(f'ERROR: body overflows past $C300 by {-pad}', file=sys.stderr)
    sys.exit(1)
code.extend([0xEA] * pad)
# Append nibble table
code.extend(NIBBLE)

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

with open('tools/peek_dl.prg', 'wb') as f:
    f.write(prg)
print(f'; wrote tools/peek_dl.prg ({len(prg)} bytes)', file=sys.stderr)
print(f'; expected screen rows:', file=sys.stderr)
print(f';   row 0 ($0400): 8 bytes from $3100', file=sys.stderr)
print(f';   row 1 ($0428): 8 bytes from $3120', file=sys.stderr)
print(f';   row 2 ($0450): 8 bytes from $3200', file=sys.stderr)
print(f';   row 3 ($0478): 8 bytes from $3220', file=sys.stderr)
