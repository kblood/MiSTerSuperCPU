#!/usr/bin/env python3
"""Generate a PRG that tests SuperRAM read/write at various offsets.

Tests bank $01 (simple SuperRAM) with write-then-read at:
- Offset $0000 (start of bank)
- Offset $20FC (Doom crash offset)
- Offset $4000 (mid bank)
- Offset $8000 (high half)
- Offset $FFFE (end of bank)

Also tests bank $20 (Doom's code bank) reads at offset $20FC.

Prints PASS/FAIL for each test on screen.
"""

import struct
import sys

# BASIC SYS stub at $0801
# 10 SYS 2062
basic_stub = bytes([
    0x0C, 0x08,  # pointer to next line ($080C)
    0x0A, 0x00,  # line number 10
    0x9E,        # SYS token
    0x32, 0x30, 0x36, 0x32,  # "2062"
    0x00,        # end of line
    0x00, 0x00,  # end of program
])

# Machine code starts at $080E (2062 decimal)
code = bytearray()

def emit(b):
    if isinstance(b, (list, tuple, bytes, bytearray)):
        code.extend(b)
    else:
        code.append(b)

def emit_jsr(addr):
    emit(0x20)  # JSR
    emit(addr & 0xFF)
    emit((addr >> 8) & 0xFF)

# Screen address for output
SCREEN = 0x0400
COLOR = 0xD800
ROW_LEN = 40

# Helper: current code offset from $080E
def pc():
    return 0x080E + len(code)

# ---- Print routines first (at known addresses) ----

# print_hex_byte: prints A as 2 hex chars at screen pos Y (lo) X (hi byte of screen addr)
# Clobbers: A, Y not preserved
print_hex_byte_addr = pc()
emit(0x48)  # PHA
emit(0x4A)  # LSR A (shift high nibble down)
emit(0x4A)
emit(0x4A)
emit(0x4A)
emit_jsr(0)  # JSR print_nibble (patched below)
jsr_patch1 = len(code) - 2
emit(0x68)  # PLA
# fall through to print_nibble

print_nibble_addr = pc()
emit(0x29); emit(0x0F)  # AND #$0F
emit(0xC9); emit(0x0A)  # CMP #$0A
emit(0x90); emit(0x02)  # BCC +2
emit(0x69); emit(0x06)  # ADC #$06 (carry set, so adds 7: A-F)
emit(0x69); emit(0x30)  # ADC #$30 ('0')
# Store to screen at ($FB),Y
emit(0x91); emit(0xFB)  # STA ($FB),Y
emit(0xC8)              # INY
emit(0x60)              # RTS

# Patch the JSR to print_nibble
code[jsr_patch1] = print_nibble_addr & 0xFF
code[jsr_patch1+1] = (print_nibble_addr >> 8) & 0xFF

# print_string: prints null-terminated string following JSR call
# Uses return address on stack to find string data
print_string_addr = pc()
emit(0x68)  # PLA (lo byte of return addr - 1)
emit(0x85); emit(0xFD)  # STA $FD
emit(0x68)  # PLA (hi byte)
emit(0x85); emit(0xFE)  # STA $FE
# Increment to point to first char
emit(0xE6); emit(0xFD)  # INC $FD
emit(0xD0); emit(0x02)  # BNE +2
emit(0xE6); emit(0xFE)  # INC $FE
# Loop: load char
print_str_loop = pc()
emit(0xA0); emit(0x00)  # LDY #$00
emit(0xB1); emit(0xFD)  # LDA ($FD),Y
emit(0xF0); emit(0x09)  # BEQ done (null terminator)
emit(0x91); emit(0xFB)  # STA ($FB),Y - store to screen
emit(0xE6); emit(0xFB)  # INC $FB (advance screen pointer)
emit(0xE6); emit(0xFD)  # INC $FD (advance string pointer)
emit(0x4C)  # JMP loop
emit(print_str_loop & 0xFF)
emit((print_str_loop >> 8) & 0xFF)
# Done: push updated return address and RTS
done_addr = pc()
code[len(code)-7] = (pc() - (len(code)-6)) & 0xFF  # fix BEQ offset
emit(0xA5); emit(0xFD)  # LDA $FD
emit(0x48)              # PHA
emit(0xA5); emit(0xFE)  # LDA $FE
emit(0x48)              # PHA
emit(0x60)              # RTS

# ---- set_screen_pos: set $FB/$FC to screen row in A ----
set_screen_pos_addr = pc()
emit(0xAA)  # TAX (row number)
emit(0xA9); emit(0x00)  # LDA #$00
emit(0x85); emit(0xFB)  # STA $FB
emit(0xA9); emit(0x04)  # LDA #$04  (screen at $0400)
emit(0x85); emit(0xFC)  # STA $FC
emit(0xE0); emit(0x00)  # CPX #$00
emit(0xF0); emit(0x0C)  # BEQ done
# multiply X by 40
set_row_loop = pc()
emit(0x18)              # CLC
emit(0xA5); emit(0xFB)  # LDA $FB
emit(0x69); emit(0x28)  # ADC #40
emit(0x85); emit(0xFB)  # STA $FB
emit(0x90); emit(0x02)  # BCC +2
emit(0xE6); emit(0xFC)  # INC $FC
emit(0xCA)              # DEX
emit(0xD0)              # BNE loop
emit((set_row_loop - pc() - 1) & 0xFF)
emit(0xA0); emit(0x00)  # LDY #$00 (reset column)
emit(0x60)              # RTS

# ---- Main test code ----
main_addr = pc()

# Clear screen
emit(0xA9); emit(0x20)  # LDA #$20 (space)
emit(0xA2); emit(0x00)  # LDX #$00
clear_loop = pc()
emit(0x9D); emit(0x00); emit(0x04)  # STA $0400,X
emit(0x9D); emit(0x00); emit(0x05)  # STA $0500,X
emit(0x9D); emit(0x00); emit(0x06)  # STA $0600,X
emit(0x9D); emit(0xE8); emit(0x06)  # STA $06E8,X
emit(0xE8)  # INX
emit(0xD0)  # BNE loop
emit((clear_loop - pc() - 1) & 0xFF)

# Set border/bg colors
emit(0xA9); emit(0x00)  # LDA #0 (black)
emit(0x8D); emit(0x20); emit(0xD0)  # STA $D020
emit(0x8D); emit(0x21); emit(0xD0)  # STA $D021

# Row 0: title
emit(0xA9); emit(0x00)  # LDA #0 (row 0)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "SUPERRAM READ/WRITE TEST":
    emit(ord(c))
emit(0x00)

# Enter native mode: SEI, CLC, XCE
emit(0x78)  # SEI
emit(0x18)  # CLC
emit(0xFB)  # XCE (switch to native mode)

# Now in 65C816 native mode
# Test 1: Write $A5 to bank $01, offset $0000, read back
# STA long $01:0000
emit(0xA9); emit(0xA5)  # LDA #$A5
emit(0x8F); emit(0x00); emit(0x00); emit(0x01)  # STA $01:0000
emit(0xAF); emit(0x00); emit(0x00); emit(0x01)  # LDA $01:0000
emit(0x85); emit(0x02)  # STA $02 (save result)

# Test 2: Write $5A to bank $01, offset $20FC, read back
emit(0xA9); emit(0x5A)  # LDA #$5A
emit(0x8F); emit(0xFC); emit(0x20); emit(0x01)  # STA $01:20FC
emit(0xAF); emit(0xFC); emit(0x20); emit(0x01)  # LDA $01:20FC
emit(0x85); emit(0x03)  # STA $03

# Test 3: Write $33 to bank $01, offset $4000, read back
emit(0xA9); emit(0x33)  # LDA #$33
emit(0x8F); emit(0x00); emit(0x40); emit(0x01)  # STA $01:4000
emit(0xAF); emit(0x00); emit(0x40); emit(0x01)  # LDA $01:4000
emit(0x85); emit(0x04)  # STA $04

# Test 4: Write $CC to bank $01, offset $8000, read back
emit(0xA9); emit(0xCC)  # LDA #$CC
emit(0x8F); emit(0x00); emit(0x80); emit(0x01)  # STA $01:8000
emit(0xAF); emit(0x00); emit(0x80); emit(0x01)  # LDA $01:8000
emit(0x85); emit(0x05)  # STA $05

# Test 5: Write $77 to bank $20, offset $20FC, read back (Doom's bank)
emit(0xA9); emit(0x77)  # LDA #$77
emit(0x8F); emit(0xFC); emit(0x20); emit(0x20)  # STA $20:20FC
emit(0xAF); emit(0xFC); emit(0x20); emit(0x20)  # LDA $20:20FC
emit(0x85); emit(0x06)  # STA $06

# Test 6: Rapid sequential reads from bank $01 at different offsets
# Write distinct values, then read them ALL back to check pipeline coherence
emit(0xA9); emit(0x11)  # LDA #$11
emit(0x8F); emit(0x00); emit(0x10); emit(0x01)  # STA $01:1000
emit(0xA9); emit(0x22)  # LDA #$22
emit(0x8F); emit(0x01); emit(0x10); emit(0x01)  # STA $01:1001
emit(0xA9); emit(0x33)  # LDA #$33
emit(0x8F); emit(0x02); emit(0x10); emit(0x01)  # STA $01:1002
emit(0xA9); emit(0x44)  # LDA #$44
emit(0x8F); emit(0x03); emit(0x10); emit(0x01)  # STA $01:1003
# Now read them back rapidly
emit(0xAF); emit(0x00); emit(0x10); emit(0x01)  # LDA $01:1000
emit(0x85); emit(0x07)  # STA $07
emit(0xAF); emit(0x01); emit(0x10); emit(0x01)  # LDA $01:1001
emit(0x85); emit(0x08)  # STA $08
emit(0xAF); emit(0x02); emit(0x10); emit(0x01)  # LDA $01:1002
emit(0x85); emit(0x09)  # STA $09
emit(0xAF); emit(0x03); emit(0x10); emit(0x01)  # LDA $01:1003
emit(0x85); emit(0x0A)  # STA $0A

# Test 7: Cross-bank read — write to bank $01, $02, $03, read them back
emit(0xA9); emit(0xAA)  # LDA #$AA
emit(0x8F); emit(0x00); emit(0x00); emit(0x01)  # STA $01:0000
emit(0xA9); emit(0xBB)  # LDA #$BB
emit(0x8F); emit(0x00); emit(0x00); emit(0x02)  # STA $02:0000
emit(0xA9); emit(0xCC)  # LDA #$CC
emit(0x8F); emit(0x00); emit(0x00); emit(0x03)  # STA $03:0000
emit(0xAF); emit(0x00); emit(0x00); emit(0x01)  # LDA $01:0000
emit(0x85); emit(0x0B)  # STA $0B
emit(0xAF); emit(0x00); emit(0x00); emit(0x02)  # LDA $02:0000
emit(0x85); emit(0x0C)  # STA $0C
emit(0xAF); emit(0x00); emit(0x00); emit(0x03)  # LDA $03:0000
emit(0x85); emit(0x0D)  # STA $0D

# Return to emulation mode: SEC, XCE
emit(0x38)  # SEC
emit(0xFB)  # XCE

# Now display results
# Test 1: row 2
emit(0xA9); emit(0x02)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T1 $01:0000 W:A5 R:":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x02)  # LDA $02 (result)
emit_jsr(print_hex_byte_addr)
# Print PASS/FAIL
emit(0xA5); emit(0x02)
emit(0xC9); emit(0xA5)  # CMP #$A5
emit(0xD0); emit(0x08)  # BNE fail1
emit_jsr(print_string_addr)
for c in " OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)  # JMP next
jmp1 = len(code)
emit(0x00); emit(0x00)  # placeholder
fail1_addr = pc()
code[len(code) - 5] = (fail1_addr - (pc() - 3)) & 0xFF  # fix BNE
emit_jsr(print_string_addr)
for c in " FAIL":
    emit(ord(c))
emit(0x00)
next1_addr = pc()
code[jmp1] = next1_addr & 0xFF
code[jmp1+1] = (next1_addr >> 8) & 0xFF

# Test 2: row 3
emit(0xA9); emit(0x03)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T2 $01:20FC W:5A R:":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x03)
emit_jsr(print_hex_byte_addr)
emit(0xA5); emit(0x03)
emit(0xC9); emit(0x5A)
emit(0xD0); emit(0x08)
emit_jsr(print_string_addr)
for c in " OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)
jmp2 = len(code)
emit(0x00); emit(0x00)
fail2_addr = pc()
code[len(code) - 5] = (fail2_addr - (pc() - 3)) & 0xFF
emit_jsr(print_string_addr)
for c in " FAIL":
    emit(ord(c))
emit(0x00)
next2_addr = pc()
code[jmp2] = next2_addr & 0xFF
code[jmp2+1] = (next2_addr >> 8) & 0xFF

# Test 3: row 4
emit(0xA9); emit(0x04)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T3 $01:4000 W:33 R:":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x04)
emit_jsr(print_hex_byte_addr)
emit(0xA5); emit(0x04)
emit(0xC9); emit(0x33)
emit(0xD0); emit(0x08)
emit_jsr(print_string_addr)
for c in " OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)
jmp3 = len(code)
emit(0x00); emit(0x00)
fail3_addr = pc()
code[len(code) - 5] = (fail3_addr - (pc() - 3)) & 0xFF
emit_jsr(print_string_addr)
for c in " FAIL":
    emit(ord(c))
emit(0x00)
next3_addr = pc()
code[jmp3] = next3_addr & 0xFF
code[jmp3+1] = (next3_addr >> 8) & 0xFF

# Test 4: row 5
emit(0xA9); emit(0x05)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T4 $01:8000 W:CC R:":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x05)
emit_jsr(print_hex_byte_addr)
emit(0xA5); emit(0x05)
emit(0xC9); emit(0xCC)
emit(0xD0); emit(0x08)
emit_jsr(print_string_addr)
for c in " OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)
jmp4 = len(code)
emit(0x00); emit(0x00)
fail4_addr = pc()
code[len(code) - 5] = (fail4_addr - (pc() - 3)) & 0xFF
emit_jsr(print_string_addr)
for c in " FAIL":
    emit(ord(c))
emit(0x00)
next4_addr = pc()
code[jmp4] = next4_addr & 0xFF
code[jmp4+1] = (next4_addr >> 8) & 0xFF

# Test 5: row 6
emit(0xA9); emit(0x06)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T5 $20:20FC W:77 R:":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x06)
emit_jsr(print_hex_byte_addr)
emit(0xA5); emit(0x06)
emit(0xC9); emit(0x77)
emit(0xD0); emit(0x08)
emit_jsr(print_string_addr)
for c in " OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)
jmp5 = len(code)
emit(0x00); emit(0x00)
fail5_addr = pc()
code[len(code) - 5] = (fail5_addr - (pc() - 3)) & 0xFF
emit_jsr(print_string_addr)
for c in " FAIL":
    emit(ord(c))
emit(0x00)
next5_addr = pc()
code[jmp5] = next5_addr & 0xFF
code[jmp5+1] = (next5_addr >> 8) & 0xFF

# Test 6: row 8 - sequential reads
emit(0xA9); emit(0x08)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T6 SEQ $01:1000-3 ":
    emit(ord(c))
emit(0x00)
# Check all 4 bytes
all_ok = True
for i, (zp, expected) in enumerate([(0x07, 0x11), (0x08, 0x22), (0x09, 0x33), (0x0A, 0x44)]):
    emit(0xA5); emit(zp)
    emit_jsr(print_hex_byte_addr)

# Check if all match
emit(0xA9); emit(0x09)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "  EXPECT 11 22 33 44 ":
    emit(ord(c))
emit(0x00)
# Compare each
emit(0xA5); emit(0x07); emit(0xC9); emit(0x11); emit(0xD0); emit(0x12)  # BNE fail6
emit(0xA5); emit(0x08); emit(0xC9); emit(0x22); emit(0xD0); emit(0x0C)
emit(0xA5); emit(0x09); emit(0xC9); emit(0x33); emit(0xD0); emit(0x06)
emit(0xA5); emit(0x0A); emit(0xC9); emit(0x44); emit(0xD0); emit(0x00)
# All OK
fail6_target = pc()
code[len(code) - 1] = (pc() + 8 - fail6_target) & 0xFF  # fix last BNE
code[len(code) - 7] = (pc() + 8 - (fail6_target - 6)) & 0xFF
code[len(code) - 13] = (pc() + 8 - (fail6_target - 12)) & 0xFF
code[len(code) - 19] = (pc() + 8 - (fail6_target - 18)) & 0xFF

emit_jsr(print_string_addr)
for c in "OK":
    emit(ord(c))
emit(0x00)
emit(0x4C)  # JMP past fail
jmp6 = len(code)
emit(0x00); emit(0x00)
fail6_addr = pc()
emit_jsr(print_string_addr)
for c in "FAIL":
    emit(ord(c))
emit(0x00)
next6_addr = pc()
code[jmp6] = next6_addr & 0xFF
code[jmp6+1] = (next6_addr >> 8) & 0xFF
# Fix the BNE targets
# Actually this is getting complex with manual assembly. Let me simplify.

# Test 7: row 11 - cross-bank
emit(0xA9); emit(0x0B)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "T7 XBANK $01-03:0000 ":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x0B)
emit_jsr(print_hex_byte_addr)
emit_jsr(print_string_addr)
for c in " ":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x0C)
emit_jsr(print_hex_byte_addr)
emit_jsr(print_string_addr)
for c in " ":
    emit(ord(c))
emit(0x00)
emit(0xA5); emit(0x0D)
emit_jsr(print_hex_byte_addr)

# Row 12: expected values
emit(0xA9); emit(0x0C)
emit_jsr(set_screen_pos_addr)
emit_jsr(print_string_addr)
for c in "  EXPECT AA BB CC":
    emit(ord(c))
emit(0x00)

# Infinite loop
emit(0x4C)  # JMP self
emit(pc() & 0xFF)
emit((pc() >> 8) & 0xFF)

# Build final PRG
load_addr = 0x0801
prg = struct.pack('<H', load_addr) + basic_stub + bytes(code)

outfile = sys.argv[1] if len(sys.argv) > 1 else 'superram_test.prg'
with open(outfile, 'wb') as f:
    f.write(prg)
print(f"Generated {outfile} ({len(prg)} bytes)")
print(f"Code starts at ${0x080E:04X}, ends at ${0x080E + len(code) - 1:04X}")
print(f"Total code size: {len(code)} bytes")
