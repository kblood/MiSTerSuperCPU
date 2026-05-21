#!/usr/bin/env python3
"""
Generate a tiny PRG that reads memory from a specified range and
displays it as hex on screen. Designed to be injected into a running
C64 via NMI or loaded separately.

This PRG:
1. Reads 64 bytes from $82C0-$82FF
2. Writes hex representation to screen RAM ($0400)
3. Loops forever

Load address: $C000 (out of way of the demo)
"""

import struct

code = bytearray()

# Target memory range
START_ADDR = 0x82C0
NUM_BYTES = 64
SCREEN = 0x0400
COLOR_RAM = 0xD800

# PRG load address
LOAD_ADDR = 0xC000

def emit(b):
    code.extend(b if isinstance(b, (bytes, bytearray)) else bytes([b]))

def emit_byte(opcode, operand=None):
    emit(opcode)
    if operand is not None:
        if isinstance(operand, int):
            emit(operand & 0xFF)
        else:
            emit(operand)

def emit_abs(opcode, addr):
    emit(opcode)
    emit(addr & 0xFF)
    emit((addr >> 8) & 0xFF)

# SEI - disable interrupts
emit_byte(0x78)

# SEC; XCE - enter emulation mode (in case we're in native)
emit_byte(0x38)  # SEC
emit_byte(0xFB)  # XCE

# LDA #$00; STA $D020; STA $D021 - black border/background
emit_byte(0xA9, 0x00)
emit_abs(0x8D, 0xD020)
emit_byte(0xA9, 0x00)
emit_abs(0x8D, 0xD021)

# Clear screen with spaces
emit_byte(0xA9, 0x20)  # LDA #$20 (space)
emit_byte(0xA2, 0x00)  # LDX #$00
# loop:
loop_clear = len(code)
emit_abs(0x9D, SCREEN)        # STA $0400,X
emit_abs(0x9D, SCREEN+0x100)  # STA $0500,X
emit_abs(0x9D, SCREEN+0x200)  # STA $0600,X
emit_abs(0x9D, SCREEN+0x2E8)  # STA $06E8,X
emit_byte(0xE8)  # INX
emit_byte(0xD0, (loop_clear - len(code)) & 0xFF)  # BNE loop

# Set color RAM to white
emit_byte(0xA9, 0x01)  # LDA #$01 (white)
emit_byte(0xA2, 0x00)  # LDX #$00
loop_color = len(code)
emit_abs(0x9D, COLOR_RAM)        # STA $D800,X
emit_abs(0x9D, COLOR_RAM+0x100)  # STA $D900,X
emit_abs(0x9D, COLOR_RAM+0x200)  # STA $DA00,X
emit_abs(0x9D, COLOR_RAM+0x2E8)  # STA $DBE8,X
emit_byte(0xE8)  # INX
emit_byte(0xD0, (loop_color - len(code)) & 0xFF)  # BNE loop

# Write header: "MEM $82C0-$82FF"
header = b"MEM $82C0-$82FF"
for i, ch in enumerate(header):
    # Convert ASCII to screen codes
    sc = ch
    if 0x41 <= ch <= 0x5A:  # A-Z
        sc = ch - 0x40
    elif 0x61 <= ch <= 0x7A:  # a-z
        sc = ch - 0x60
    elif ch == 0x24:  # $
        sc = 0x24
    elif ch == 0x2D:  # -
        sc = 0x2D
    emit_byte(0xA9, sc)
    emit_abs(0x8D, SCREEN + i)

# Now read and display memory
# hex_chars table at end of code (0-F screen codes)
# For each byte at START_ADDR+offset: read it, split into nybbles,
# look up hex char, write to screen

# We'll put hex output starting at row 2 (offset 80 = 2*40)
# Format: "xx xx xx xx xx xx xx xx  xx xx xx xx xx xx xx xx"
# That's 16 bytes per row, 4 rows for 64 bytes

screen_offset = 80  # Row 2

emit_byte(0xA2, 0x00)  # LDX #$00 (byte counter 0-63)

main_loop = len(code)

# LDA START_ADDR,X
emit_abs(0xBD, START_ADDR)  # LDA $82C0,X

# Save A to temp
emit_byte(0x85, 0x02)  # STA $02

# High nybble: LSR x4
emit_byte(0x4A)  # LSR
emit_byte(0x4A)  # LSR
emit_byte(0x4A)  # LSR
emit_byte(0x4A)  # LSR
emit_byte(0xA8)  # TAY

# Load hex char from table
# hex_table address will be filled in later
hex_table_ref1 = len(code)
emit_abs(0xB9, 0x0000)  # LDA hex_table,Y (patched later)

# Calculate screen position
# screen_pos = screen_offset + (X/16)*40 + (X%16)*3
# We'll use a lookup table for screen positions instead
# Actually simpler: just keep a screen pointer in ZP
# Use $FB/$FC as screen pointer

# Let's use a different approach: pre-compute with just an offset counter
# Store high nybble char
emit_byte(0x48)  # PHA (save high nybble char)

# Get low nybble
emit_byte(0xA5, 0x02)  # LDA $02
emit_byte(0x29, 0x0F)  # AND #$0F
emit_byte(0xA8)  # TAY
hex_table_ref2 = len(code)
emit_abs(0xB9, 0x0000)  # LDA hex_table,Y (patched later)

# Now store both chars. We need a screen position.
# Use ZP $FB/$FC as screen pointer, initialized before the loop
emit_byte(0xA0, 0x01)  # LDY #$01
emit_abs(0x91, 0x00FB)  # STA ($FB),Y - low nybble at pos+1

emit_byte(0x68)  # PLA (high nybble char)
emit_byte(0xA0, 0x00)  # LDY #$00
emit_abs(0x91, 0x00FB)  # STA ($FB),Y - high nybble at pos+0

# Advance screen pointer by 3 (2 hex chars + 1 space)
emit_byte(0x18)  # CLC
emit_byte(0xA5, 0xFB)  # LDA $FB
emit_byte(0x69, 0x03)  # ADC #$03
emit_byte(0x85, 0xFB)  # STA $FB
emit_byte(0x90, 0x02)  # BCC +2
emit_byte(0xE6, 0xFC)  # INC $FC

# Check if we need newline (every 16 bytes)
emit_byte(0xE8)  # INX
emit_byte(0x8A)  # TXA
emit_byte(0x29, 0x0F)  # AND #$0F
emit_byte(0xD0, 0x0E)  # BNE skip_newline (14 bytes ahead)

# Newline: set screen pointer to next row
# Current row start = screen_offset + (X/16)*40
# Actually just add (40 - 16*3) = (40-48) = -8... that's negative
# 16 bytes * 3 chars = 48, but a row is 40 chars. So we need to wrap.
# Let's just use 8 bytes per row instead: 8*3=24 chars fits in 40

# Actually, let me recalculate. We advanced by 3*16=48 from row start.
# We need to go back by 48 and forward by 40 = subtract 8.
emit_byte(0x38)  # SEC
emit_byte(0xA5, 0xFB)  # LDA $FB
emit_byte(0xE9, 0x08)  # SBC #$08
emit_byte(0x85, 0xFB)  # STA $FB
emit_byte(0xB0, 0x02)  # BCS +2
emit_byte(0xC6, 0xFC)  # DEC $FC
# skip_newline:

# Check if done (X == 64)
emit_byte(0xE0, NUM_BYTES)  # CPX #64
branch_target = main_loop - len(code) - 2
emit_byte(0xD0, branch_target & 0xFF)  # BNE main_loop

# Done - infinite loop
done_loop = len(code)
emit_byte(0x4C)  # JMP done_loop
emit(done_loop + LOAD_ADDR & 0xFF)
emit(((done_loop + LOAD_ADDR) >> 8) & 0xFF)

# Hex character table (screen codes for 0-9, A-F)
hex_table = len(code)
emit(bytes([0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))

# Patch hex table references
code[hex_table_ref1 + 1] = (hex_table + LOAD_ADDR) & 0xFF
code[hex_table_ref1 + 2] = ((hex_table + LOAD_ADDR) >> 8) & 0xFF
code[hex_table_ref2 + 1] = (hex_table + LOAD_ADDR) & 0xFF
code[hex_table_ref2 + 2] = ((hex_table + LOAD_ADDR) >> 8) & 0xFF

print(f"Code size: {len(code)} bytes")
print(f"Load address: ${LOAD_ADDR:04X}")
print(f"Hex table at: ${hex_table + LOAD_ADDR:04X}")

# Oops this is getting complicated with the indirect addressing.
# Let me just write it more carefully as raw bytes.

print("\nActually, let me generate a simpler version...")

# --- SIMPLER VERSION ---
code2 = bytearray()

def add(*args):
    code2.extend(args)

BASE = 0xC000

# SEI
add(0x78)
# SEC; XCE (enter emulation mode)
add(0x38, 0xFB)

# LDA #$00; STA $D020 (black border)
add(0xA9, 0x00, 0x8D, 0x20, 0xD0)
# STA $D021 (black bg)
add(0x8D, 0x21, 0xD0)

# Initialize screen pointer $FB/$FC to $0400 + 80 (row 2)
add(0xA9, 0x50)  # LDA #$50 ($0400+80 = $0450)
add(0x85, 0xFB)  # STA $FB
add(0xA9, 0x04)  # LDA #$04
add(0x85, 0xFC)  # STA $FC

# X = byte counter
add(0xA2, 0x00)  # LDX #$00

# Main loop label (will be at offset 16 from BASE)
main_off = len(code2)

# LDA $82C0,X
add(0xBD, 0xC0, 0x82)

# Store in temp
add(0x85, 0x02)  # STA $02

# High nybble
add(0x4A, 0x4A, 0x4A, 0x4A)  # LSR x4
add(0xA8)  # TAY
# hex_table address: will be at end
add(0xB9, 0x00, 0x00)  # LDA hex_table,Y  -- PATCH bytes 27,28
ht_ref1 = len(code2) - 2

add(0xA0, 0x00)  # LDY #0
add(0x91, 0xFB)  # STA ($FB),Y

# Low nybble
add(0xA5, 0x02)  # LDA $02
add(0x29, 0x0F)  # AND #$0F
add(0xA8)  # TAY
add(0xB9, 0x00, 0x00)  # LDA hex_table,Y  -- PATCH
ht_ref2 = len(code2) - 2

add(0xA0, 0x01)  # LDY #1
add(0x91, 0xFB)  # STA ($FB),Y

# Advance screen pointer by 3
add(0x18)  # CLC
add(0xA5, 0xFB)  # LDA $FB
add(0x69, 0x03)  # ADC #3
add(0x85, 0xFB)  # STA $FB
add(0x90, 0x02)  # BCC +2
add(0xE6, 0xFC)  # INC $FC

# INX
add(0xE8)

# Every 16 bytes, adjust for new line
add(0x8A)  # TXA
add(0x29, 0x0F)  # AND #$0F
add(0xD0, 0x0E)  # BNE skip_newline (+14)

# Newline: we advanced 16*3=48 bytes on screen, but row is 40
# So subtract 8 to align to next row start
# Actually: we want to go back 48 and forward 40 from the row start
# Net: subtract 8 from current pointer
add(0x38)  # SEC
add(0xA5, 0xFB)  # LDA $FB
add(0xE9, 0x08)  # SBC #8
add(0x85, 0xFB)  # STA $FB
add(0xB0, 0x02)  # BCS +2
add(0xC6, 0xFC)  # DEC $FC
# Extra: add another row gap for readability? No, keep it simple.

# skip_newline:
add(0xE0, 0x40)  # CPX #$40 (64 bytes)

# BNE main_loop
target = main_off - len(code2) - 2
add(0xD0, target & 0xFF)

# Also write the address labels on row 1
# "$82C0:" at screen $0400
label_data = [
    0x24,  # $
    0x38,  # 8
    0x32,  # 2
    0x03,  # C (screen code)
    0x30,  # 0
    0x3A,  # :  -- actually : is screen code $1A? No.
]
# C64 screen codes: A=1, B=2, ..., Z=26; 0-9 = $30-$39
# : = screen code $1A? Let me check: PETSCII $3A = ':', screen code = $1A (yes)
label_data[5] = 0x1A

for i, sc in enumerate(label_data):
    add(0xA9, sc)            # LDA #sc
    add(0x8D, (0x0400 + i) & 0xFF, ((0x0400 + i) >> 8) & 0xFF)  # STA $0400+i

# Write "I=" and then read $82E0-$82E1 specifically on row 7
# Row 7 = offset 280 = $0400+280 = $0518
add(0xA9, 0x09)  # 'I' screen code
add(0x8D, 0x18, 0x05)
add(0xA9, 0x3D)  # '=' screen code (= is $3D in PETSCII, screen code $1D? Actually $3D)
# Hmm, C64 screen codes: $3D = '=' ? Actually equals sign:
# PETSCII $3D = '=', screen code = $3D. Let me just use it.
add(0x8D, 0x19, 0x05)

# Read byte at $82E0
add(0xAD, 0xE0, 0x82)  # LDA $82E0
add(0x85, 0x02)
# High nybble
add(0x4A, 0x4A, 0x4A, 0x4A)
add(0xA8)
add(0xB9, 0x00, 0x00)  # PATCH ht_ref3
ht_ref3 = len(code2) - 2
add(0x8D, 0x1A, 0x05)  # STA screen
# Low nybble
add(0xA5, 0x02)
add(0x29, 0x0F)
add(0xA8)
add(0xB9, 0x00, 0x00)  # PATCH ht_ref4
ht_ref4 = len(code2) - 2
add(0x8D, 0x1B, 0x05)

# Read byte at $82E1
add(0xAD, 0xE1, 0x82)  # LDA $82E1
add(0x85, 0x02)
add(0x4A, 0x4A, 0x4A, 0x4A)
add(0xA8)
add(0xB9, 0x00, 0x00)  # PATCH ht_ref5
ht_ref5 = len(code2) - 2
add(0x8D, 0x1D, 0x05)
add(0xA5, 0x02)
add(0x29, 0x0F)
add(0xA8)
add(0xB9, 0x00, 0x00)  # PATCH ht_ref6
ht_ref6 = len(code2) - 2
add(0x8D, 0x1E, 0x05)

# Space between the two hex bytes
add(0xA9, 0x20)
add(0x8D, 0x1C, 0x05)

# Set all color RAM to white
add(0xA9, 0x01)  # white
add(0xA2, 0x00)
color_loop = len(code2)
add(0x9D, 0x00, 0xD8)
add(0x9D, 0x00, 0xD9)
add(0x9D, 0x00, 0xDA)
add(0x9D, 0xE8, 0xDA)
add(0xE8)
add(0xD0, (color_loop - len(code2) - 2) & 0xFF)

# Infinite loop
inf_off = len(code2)
add(0x4C, (inf_off + BASE) & 0xFF, ((inf_off + BASE) >> 8) & 0xFF)

# Hex table
hex_off = len(code2)
# Screen codes: 0=$30, 1=$31, ..., 9=$39, A=$01, B=$02, ..., F=$06
add(0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06)

# Patch all hex table references
hex_addr = hex_off + BASE
for ref in [ht_ref1, ht_ref2, ht_ref3, ht_ref4, ht_ref5, ht_ref6]:
    code2[ref] = hex_addr & 0xFF
    code2[ref + 1] = (hex_addr >> 8) & 0xFF

# Write PRG file
prg = struct.pack('<H', BASE) + bytes(code2)
outfile = "C:/LLM/C64/MiSTerSuperCPU/memdump.prg"
with open(outfile, 'wb') as f:
    f.write(prg)

print(f"Generated: {outfile}")
print(f"Code size: {len(code2)} bytes")
print(f"Load addr: ${BASE:04X}-${BASE+len(code2)-1:04X}")
print(f"Hex table: ${hex_addr:04X}")
print(f"\nThis PRG reads $82C0-$82FF and displays as hex on screen.")
print(f"Row 1: '$82C0:' label")
print(f"Row 2-5: 64 bytes in hex (16 per row)")
print(f"Row 7: 'I=xx yy' showing bytes at $82E0-$82E1")
