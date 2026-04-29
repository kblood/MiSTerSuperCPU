#!/usr/bin/env python3
"""Generate a SuperCPU register test PRG for C64.

Reads key registers, displays values as hex on screen,
then tests register enable/disable and speed switching.

Screen layout (row, content):
  Row 0: SCPU REG TEST V2
  Row 2: D0BC=xx (expect C9)
  Row 3: D0B0=xx (expect 40)
  Row 4: D0B2=xx (expect 00)
  Row 5: D0B4=xx (optim mode)
  Row 6: D0B5=xx (speed switch)
  Row 7: D0B8=xx (speed status)
  Row 8: D07E=xx (ROM vis)
  Row 10: DISABLE TEST:
  Row 11: D0BC=xx (expect FF after D07F write)
  Row 13: RE-ENABLE TEST:
  Row 14: D0BC=xx (expect C9 after D07E write)
"""

import struct

code_start = 0x0801  # BASIC start

# Build machine code at $0820 (after BASIC stub)
mc_start = 0x0820

# Helper: hex digit to PETSCII screen code
# '0'-'9' = $30-$39, 'A'-'F' = $01-$06 (screen codes)
def petscii_screen(ch):
    if ch >= ord('0') and ch <= ord('9'):
        return ch - 0x30 + 0x30
    elif ch >= ord('A') and ch <= ord('F'):
        return ch - ord('A') + 1
    return ch

# Screen codes for text strings
def text_to_screen(s):
    result = []
    for c in s.upper():
        if c == ' ':
            result.append(0x20)
        elif c == '=':
            result.append(0x3D)
        elif c == ':':
            result.append(0x3A)
        elif c >= '0' and c <= '9':
            result.append(ord(c) - ord('0') + 0x30)
        elif c >= 'A' and c <= 'Z':
            result.append(ord(c) - ord('A') + 1)
        else:
            result.append(0x20)
    return result

# 6502 assembly as bytes
asm = bytearray()

def emit(*args):
    for b in args:
        asm.append(b & 0xFF)

def emit_jsr(addr):
    emit(0x20, addr & 0xFF, (addr >> 8) & 0xFF)

# Addresses
SCREEN = 0x0400
COLOR = 0xD800

# Subroutine addresses (we'll fix these up later)
# print_hex at end of main code
# print_text at end

# --- Main code ---
# Clear screen first (fill $0400-$07E7 with spaces)
# LDA #$20; LDX #$00; loop: STA $0400,X; STA $0500,X; STA $0600,X; STA $0700,X; INX; BNE loop
emit(0xA9, 0x20)       # LDA #$20 (space)
emit(0xA2, 0x00)       # LDX #0
# clear_loop:
clear_loop = len(asm)
emit(0x9D, 0x00, 0x04) # STA $0400,X
emit(0x9D, 0x00, 0x05) # STA $0500,X
emit(0x9D, 0x00, 0x06) # STA $0600,X
emit(0x9D, 0x00, 0x07) # STA $0700,X
emit(0xE8)             # INX
emit(0xD0, -(len(asm) - clear_loop + 2) & 0xFF)  # BNE clear_loop

# Also set color RAM to light green (color 13)
emit(0xA9, 0x0D)       # LDA #13 (light green)
emit(0xA2, 0x00)       # LDX #0
color_loop = len(asm)
emit(0x9D, 0x00, 0xD8) # STA $D800,X
emit(0x9D, 0x00, 0xD9) # STA $D900,X
emit(0x9D, 0x00, 0xDA) # STA $DA00,X
emit(0x9D, 0x00, 0xDB) # STA $DB00,X
emit(0xE8)             # INX
emit(0xD0, -(len(asm) - color_loop + 2) & 0xFF)  # BNE color_loop

# Row 0: Title "SCPU REG TEST V2"
title = text_to_screen("SCPU REG TEST V2")
for i, ch in enumerate(title):
    emit(0xA9, ch)              # LDA #ch
    emit(0x8D, (SCREEN + i) & 0xFF, (SCREEN + i) >> 8)  # STA screen+i

# --- Read and display registers ---
# We'll use a pattern: read register, store to ZP, then write hex to screen

# Helper ZP locations
ZP_VAL = 0xFB  # value to print
ZP_SCR_LO = 0xFC  # screen pointer low
ZP_SCR_HI = 0xFD  # screen pointer high

# Row 2 ($0400 + 80): "D0BC="
row2 = SCREEN + 80
label = text_to_screen("D0BC=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row2 + i) & 0xFF, (row2 + i) >> 8)
# Read $D0BC
emit(0xAD, 0xBC, 0xD0)  # LDA $D0BC
emit(0x85, ZP_VAL)       # STA $FB
# Print hex at row2+5
scr_pos = row2 + 5
emit(0xA9, scr_pos & 0xFF)        # LDA #lo
emit(0x85, ZP_SCR_LO)             # STA $FC
emit(0xA9, (scr_pos >> 8) & 0xFF) # LDA #hi
emit(0x85, ZP_SCR_HI)             # STA $FD
print_hex_addr = None  # will be resolved
emit_jsr(0x0000)  # placeholder JSR print_hex
jsr_fixup_1 = len(asm) - 2  # save position for fixup

# Row 3: D0B0=
row3 = SCREEN + 120
label = text_to_screen("D0B0=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row3 + i) & 0xFF, (row3 + i) >> 8)
emit(0xAD, 0xB0, 0xD0)  # LDA $D0B0
emit(0x85, ZP_VAL)
scr_pos = row3 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_2 = len(asm) - 2

# Row 4: D0B2=
row4 = SCREEN + 160
label = text_to_screen("D0B2=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row4 + i) & 0xFF, (row4 + i) >> 8)
emit(0xAD, 0xB2, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row4 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_3 = len(asm) - 2

# Row 5: D0B4=
row5 = SCREEN + 200
label = text_to_screen("D0B4=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row5 + i) & 0xFF, (row5 + i) >> 8)
emit(0xAD, 0xB4, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row5 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_4 = len(asm) - 2

# Row 6: D0B5=
row6 = SCREEN + 240
label = text_to_screen("D0B5=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row6 + i) & 0xFF, (row6 + i) >> 8)
emit(0xAD, 0xB5, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row6 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_5 = len(asm) - 2

# Row 7: D0B8=
row7 = SCREEN + 280
label = text_to_screen("D0B8=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row7 + i) & 0xFF, (row7 + i) >> 8)
emit(0xAD, 0xB8, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row7 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_6 = len(asm) - 2

# Row 8: D07E=
row8 = SCREEN + 320
label = text_to_screen("D07E=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row8 + i) & 0xFF, (row8 + i) >> 8)
emit(0xAD, 0x7E, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row8 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_7 = len(asm) - 2

# Row 10: "DISABLE TEST:"
row10 = SCREEN + 400
label = text_to_screen("DISABLE TEST:")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row10 + i) & 0xFF, (row10 + i) >> 8)

# Write to $D07F to disable registers
emit(0xA9, 0x00)         # LDA #0
emit(0x8D, 0x7F, 0xD0)   # STA $D07F

# Row 11: "D0BC=" (should be open-bus / FF)
row11 = SCREEN + 440
label = text_to_screen("D0BC=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row11 + i) & 0xFF, (row11 + i) >> 8)
emit(0xAD, 0xBC, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row11 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_8 = len(asm) - 2

# Row 13: "RE-ENABLE TEST:"
row13 = SCREEN + 520
label = text_to_screen("RE-ENABLE TEST:")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row13 + i) & 0xFF, (row13 + i) >> 8)

# Write to $D07E to re-enable registers (also sets ROM vis)
emit(0xA9, 0x00)         # LDA #0 (bit7=0: KERNAL visible)
emit(0x8D, 0x7E, 0xD0)   # STA $D07E

# Row 14: "D0BC=" (should be C9 again)
row14 = SCREEN + 560
label = text_to_screen("D0BC=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row14 + i) & 0xFF, (row14 + i) >> 8)
emit(0xAD, 0xBC, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row14 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_9 = len(asm) - 2

# Row 16: "D07E=" (after re-enable, should show ROM vis = 0 → $00)
row16 = SCREEN + 640
label = text_to_screen("D07E=")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row16 + i) & 0xFF, (row16 + i) >> 8)
emit(0xAD, 0x7E, 0xD0)
emit(0x85, ZP_VAL)
scr_pos = row16 + 5
emit(0xA9, scr_pos & 0xFF)
emit(0x85, ZP_SCR_LO)
emit(0xA9, (scr_pos >> 8) & 0xFF)
emit(0x85, ZP_SCR_HI)
emit_jsr(0x0000)
jsr_fixup_10 = len(asm) - 2

# Row 18: PASS/FAIL summary
row18 = SCREEN + 720
# Check: D0BC initial should be $C9, disabled should be != $C9
# We'll just display "DONE" for now
label = text_to_screen("DONE")
for i, ch in enumerate(label):
    emit(0xA9, ch)
    emit(0x8D, (row18 + i) & 0xFF, (row18 + i) >> 8)

# Infinite loop
emit(0x4C, (mc_start + len(asm)) & 0xFF, ((mc_start + len(asm)) >> 8) & 0xFF)  # JMP self

# --- print_hex subroutine ---
# Input: ZP_VAL ($FB) = byte to print, ($FC/$FD) = screen pointer
# Writes 2 hex chars to screen
print_hex_offset = len(asm)
print_hex_abs = mc_start + print_hex_offset

# High nibble
emit(0xA5, ZP_VAL)       # LDA $FB
emit(0x4A)                # LSR
emit(0x4A)                # LSR
emit(0x4A)                # LSR
emit(0x4A)                # LSR
emit(0xAA)                # TAX
# Load hex char from table
hex_table_jsr = len(asm)
emit(0xBD, 0x00, 0x00)   # LDA hex_table,X (fixup later)
hex_table_fixup_1 = len(asm) - 2
emit(0xA0, 0x00)          # LDY #0
emit(0x91, ZP_SCR_LO)     # STA ($FC),Y

# Low nibble
emit(0xA5, ZP_VAL)       # LDA $FB
emit(0x29, 0x0F)          # AND #$0F
emit(0xAA)                # TAX
emit(0xBD, 0x00, 0x00)   # LDA hex_table,X (fixup later)
hex_table_fixup_2 = len(asm) - 2
emit(0xC8)                # INY
emit(0x91, ZP_SCR_LO)     # STA ($FC),Y

emit(0x60)                # RTS

# Hex table (screen codes: 0-9 = $30-$39, A-F = $01-$06)
hex_table_offset = len(asm)
hex_table_abs = mc_start + hex_table_offset
for i in range(16):
    if i < 10:
        emit(0x30 + i)    # '0'-'9'
    else:
        emit(i - 10 + 1)  # A-F as screen codes $01-$06

# Fix up all JSR print_hex calls
fixups = [jsr_fixup_1, jsr_fixup_2, jsr_fixup_3, jsr_fixup_4,
          jsr_fixup_5, jsr_fixup_6, jsr_fixup_7, jsr_fixup_8,
          jsr_fixup_9, jsr_fixup_10]
for f in fixups:
    asm[f-1] = print_hex_abs & 0xFF
    asm[f] = (print_hex_abs >> 8) & 0xFF

# Fix up hex table references
asm[hex_table_fixup_1-1] = hex_table_abs & 0xFF
asm[hex_table_fixup_1] = (hex_table_abs >> 8) & 0xFF
asm[hex_table_fixup_2-1] = hex_table_abs & 0xFF
asm[hex_table_fixup_2] = (hex_table_abs >> 8) & 0xFF

# Build the PRG file
# BASIC stub: 10 SYS 2080 ($0820)
basic_stub = bytearray()
# Next line pointer (will be at $0801 + len)
next_line = code_start + 12  # after this line
basic_stub += struct.pack('<H', next_line)  # next line pointer
basic_stub += struct.pack('<H', 10)         # line number 10
basic_stub += bytes([0x9E])                 # SYS token
basic_stub += b'2080'                       # address as ASCII
basic_stub += bytes([0x00])                 # end of line
basic_stub += struct.pack('<H', 0x0000)     # end of program (null pointer)

# Pad from end of BASIC stub to mc_start
pad_needed = mc_start - (code_start + len(basic_stub))
basic_stub += bytes([0x00] * pad_needed)

# Combine: load address + basic stub + machine code
prg = struct.pack('<H', code_start) + basic_stub + asm

output = 'tools/regtest.prg'
with open(output, 'wb') as f:
    f.write(prg)

print(f"Generated {output}: {len(prg)} bytes")
print(f"  BASIC stub at ${code_start:04X}, SYS {mc_start}")
print(f"  Machine code: {len(asm)} bytes at ${mc_start:04X}")
print(f"  print_hex at ${print_hex_abs:04X}")
print(f"  hex_table at ${hex_table_abs:04X}")
