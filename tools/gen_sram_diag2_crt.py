#!/usr/bin/env python3
"""Diagnostic CRT v2: proper VIC-II init + stage-by-stage border color changes.

Each stage changes border to a different color so we can see how far execution gets:
- Stage 1: RED ($02) - CRT code started
- Stage 2: GREEN ($05) - VIC-II initialized, screen visible  
- Stage 3: CYAN ($03) - SuperCPU registers enabled ($D07E)
- Stage 4: Border = value read from $200000 (expect $78 → orange $08)
- Final: YELLOW ($07) - all reads complete, loop

If screen stays RED: CRT started but VIC-II init failed
If screen stays GREEN: VIC-II OK but $D07E write caused hang
If screen stays CYAN: $D07E OK but LDA $200000 hung (SDRAM read failed)
If screen shows text + some color: reads working, check hex values
"""
import struct

def make_crt(code_bytes, name="DIAG CRT V2"):
    rom = bytearray(8192)
    code_start = 0x8009
    rom[0] = code_start & 0xFF
    rom[1] = (code_start >> 8) & 0xFF
    rti_addr = 0x8009 + len(code_bytes)
    rom[2] = rti_addr & 0xFF
    rom[3] = (rti_addr >> 8) & 0xFF
    rom[4] = 0xC3; rom[5] = 0xC2; rom[6] = 0xCD; rom[7] = 0x38; rom[8] = 0x30
    for i, b in enumerate(code_bytes):
        rom[9 + i] = b
    rom[9 + len(code_bytes)] = 0x40  # RTI
    
    header = bytearray(64)
    header[0:16] = b'C64 CARTRIDGE   '
    header[0x10:0x14] = struct.pack('>I', 64)
    header[0x14:0x16] = struct.pack('>H', 0x0100)
    header[0x16:0x18] = struct.pack('>H', 0)
    header[0x18] = 0; header[0x19] = 1
    name_bytes = name.encode('ascii')[:32]
    header[0x20:0x20+len(name_bytes)] = name_bytes
    
    chip = bytearray(16)
    chip[0:4] = b'CHIP'
    chip[4:8] = struct.pack('>I', 16 + 8192)
    chip[8:10] = struct.pack('>H', 0)
    chip[10:12] = struct.pack('>H', 0)
    chip[12:14] = struct.pack('>H', 0x8000)
    chip[14:16] = struct.pack('>H', 8192)
    
    return bytes(header) + bytes(chip) + bytes(rom)

def emit_hex_byte_to_screen(code, zp_loc, screen_addr):
    """Emit code to display byte in zp_loc as 2 hex chars at screen_addr."""
    # High nibble
    code.append(0xA5); code.append(zp_loc)   # LDA zp
    code.append(0x4A); code.append(0x4A); code.append(0x4A); code.append(0x4A)  # LSR x4
    code.append(0xC9); code.append(0x0A)      # CMP #$0A
    code.append(0x90); code.append(0x04)      # BCC +4
    code.append(0x18)                          # CLC
    code.append(0x69); code.append(0x37)      # ADC #$37 (letter)
    code.append(0x80); code.append(0x02)      # BRA +2
    code.append(0x18)                          # CLC
    code.append(0x69); code.append(0x30)      # ADC #$30 (digit)
    # ASCII to screen code
    code.append(0xC9); code.append(0x41)      # CMP #$41
    code.append(0x90); code.append(0x02)      # BCC +2
    code.append(0xE9); code.append(0x40)      # SBC #$40
    code.append(0x8D); code.append(screen_addr & 0xFF); code.append(screen_addr >> 8)
    
    # Low nibble
    code.append(0xA5); code.append(zp_loc)   # LDA zp
    code.append(0x29); code.append(0x0F)      # AND #$0F
    code.append(0xC9); code.append(0x0A)
    code.append(0x90); code.append(0x04)
    code.append(0x18); code.append(0x69); code.append(0x37)
    code.append(0x80); code.append(0x02)
    code.append(0x18); code.append(0x69); code.append(0x30)
    code.append(0xC9); code.append(0x41)
    code.append(0x90); code.append(0x02)
    code.append(0xE9); code.append(0x40)
    code.append(0x8D); code.append((screen_addr+1) & 0xFF); code.append((screen_addr+1) >> 8)

code = []

# === STAGE 1: RED border - CRT code started ===
code.append(0x78)  # SEI
code.append(0xA9); code.append(0x02)  # LDA #2 (red)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# === Initialize VIC-II properly ===
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021 (bg = black)

# $D011 = $1B: screen ON, 25 rows, no y-scroll=3
code.append(0xA9); code.append(0x1B)
code.append(0x8D); code.append(0x11); code.append(0xD0)

# $D016 = $C8: 40 columns, multicolor off, x-scroll=0
code.append(0xA9); code.append(0xC8)
code.append(0x8D); code.append(0x16); code.append(0xD0)

# $D018 = $15: screen at $0400, chars at $1000 (ROM default)
code.append(0xA9); code.append(0x15)
code.append(0x8D); code.append(0x18); code.append(0xD0)

# Disable all sprites
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x15); code.append(0xD0)

# Clear screen: fill $0400-$07E7 with spaces ($20)
# Use X register as counter, clear in batches
code.append(0xA2); code.append(0x00)  # LDX #0
code.append(0xA9); code.append(0x20)  # LDA #$20 (space)
# Loop: STA $0400,X; STA $0500,X; STA $0600,X; STA $0700,X; INX; BNE loop
loop_addr = 0x8009 + len(code)
code.append(0x9D); code.append(0x00); code.append(0x04)  # STA $0400,X
code.append(0x9D); code.append(0x00); code.append(0x05)  # STA $0500,X
code.append(0x9D); code.append(0x00); code.append(0x06)  # STA $0600,X
code.append(0x9D); code.append(0x00); code.append(0x07)  # STA $0700,X
code.append(0xE8)  # INX
code.append(0xD0); code.append(256 - 16)  # BNE loop (back 16 bytes)

# Fill color RAM $D800-$DBE7 with WHITE ($01)
code.append(0xA2); code.append(0x00)  # LDX #0
code.append(0xA9); code.append(0x01)  # LDA #1 (white)
loop2_addr = 0x8009 + len(code)
code.append(0x9D); code.append(0x00); code.append(0xD8)  # STA $D800,X
code.append(0x9D); code.append(0x00); code.append(0xD9)  # STA $D900,X
code.append(0x9D); code.append(0x00); code.append(0xDA)  # STA $DA00,X
code.append(0x9D); code.append(0x00); code.append(0xDB)  # STA $DB00,X
code.append(0xE8)  # INX
code.append(0xD0); code.append(256 - 16)  # BNE loop

# === STAGE 2: GREEN border - VIC-II initialized ===
code.append(0xA9); code.append(0x05)  # LDA #5 (green)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Print "SRAM DIAG V2" on line 1
msg = [0x13, 0x12, 0x01, 0x0D, 0x20, 0x04, 0x09, 0x01, 0x07, 0x20, 0x16, 0x32]  # "SRAM DIAG V2"
for i, sc in enumerate(msg):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x0400 + i) & 0xFF); code.append((0x0400 + i) >> 8)

# Print "ENABLING D07E" on line 2
msg2 = [0x05, 0x0E, 0x01, 0x02, 0x0C, 0x09, 0x0E, 0x07, 0x20, 0x04, 0x30, 0x37, 0x05]
for i, sc in enumerate(msg2):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x0428 + i) & 0xFF); code.append((0x0428 + i) >> 8)

# === STAGE 3: CYAN border - enabling SuperCPU regs ===
code.append(0xA9); code.append(0x03)  # LDA #3 (cyan)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Enable SuperCPU registers: STA $D07E
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x7E); code.append(0xD0)

# Print "READING 200000" on line 3
msg3 = [0x12, 0x05, 0x01, 0x04, 0x09, 0x0E, 0x07, 0x20, 0x32, 0x30, 0x30, 0x30, 0x30, 0x30]
for i, sc in enumerate(msg3):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x0450 + i) & 0xFF); code.append((0x0450 + i) >> 8)

# === Read SuperRAM at $200000 using LDA absolute long ($AF) ===
# LDA $200000 = AF 00 00 20
code.append(0xAF); code.append(0x00); code.append(0x00); code.append(0x20)
code.append(0x85); code.append(0xFB)  # STA $FB (save result)

# Set border to the read value (low 4 bits)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Print "BYTE0=" on line 4, then hex value
msg4 = [0x02, 0x19, 0x14, 0x05, 0x30, 0x3D]  # "BYTE0="
for i, sc in enumerate(msg4):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x0478 + i) & 0xFF); code.append((0x0478 + i) >> 8)

emit_hex_byte_to_screen(code, 0xFB, 0x047E)  # display at position after "BYTE0="

# Read 3 more bytes
for idx, offset in enumerate([1, 2, 3]):
    code.append(0xAF); code.append(offset); code.append(0x00); code.append(0x20)
    code.append(0x85); code.append(0xFC + idx)  # STA $FC/$FD/$FE

# Display them on line 5: "78 D8 18 FB" expected
msg5 = [0x04, 0x01, 0x14, 0x01, 0x3D]  # "DATA="
for i, sc in enumerate(msg5):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x04A0 + i) & 0xFF); code.append((0x04A0 + i) >> 8)

emit_hex_byte_to_screen(code, 0xFB, 0x04A5)  # byte 0
emit_hex_byte_to_screen(code, 0xFC, 0x04A8)  # byte 1
emit_hex_byte_to_screen(code, 0xFD, 0x04AB)  # byte 2
emit_hex_byte_to_screen(code, 0xFE, 0x04AE)  # byte 3

# === FINAL: YELLOW border - all complete ===
code.append(0xA9); code.append(0x07)  # LDA #7 (yellow)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Print "DONE" on line 7
msg6 = [0x04, 0x0F, 0x0E, 0x05]  # "DONE"
for i, sc in enumerate(msg6):
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x04F0 + i) & 0xFF); code.append((0x04F0 + i) >> 8)

# Infinite loop
jmp_target = 0x8009 + len(code)
code.append(0x4C); code.append(jmp_target & 0xFF); code.append((jmp_target >> 8) & 0xFF)

print(f"Diagnostic CRT v2 code size: {len(code)} bytes")
assert len(code) < 8000, f"Code too large: {len(code)} bytes"

crt = make_crt(code, name="SRAM DIAG V2")
with open('crt/sram_diag2.crt', 'wb') as f:
    f.write(crt)
print(f"Written crt/sram_diag2.crt ({len(crt)} bytes)")

mgl = '<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/doom.reu"/>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/sram_diag2.crt"/>\n</mistergamedescription>\n'
with open('crt/sram_diag2.mgl', 'w') as f:
    f.write(mgl)
print("Written crt/sram_diag2.mgl")
