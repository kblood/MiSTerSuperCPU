#!/usr/bin/env python3
"""Generate a diagnostic CRT that tests SuperRAM reads and shows results on screen.

This CRT:
1. Changes border color (proves CRT code is running)
2. Enables SuperCPU registers ($D07E)
3. Reads SuperRAM at $200000 using LDA long (works in emulation mode)
4. Displays the read value as border color and on screen
5. Does NOT switch to native mode or JML — purely diagnostic
"""
import struct

def make_crt(code_bytes, name="DIAG CRT"):
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
    rom[9 + len(code_bytes)] = 0x40  # RTI for NMI handler
    
    header = bytearray(64)
    header[0:16] = b'C64 CARTRIDGE   '
    header[0x10:0x14] = struct.pack('>I', 64)
    header[0x14:0x16] = struct.pack('>H', 0x0100)
    header[0x16:0x18] = struct.pack('>H', 0)
    header[0x18] = 0  # EXROM=0
    header[0x19] = 1  # GAME=1 (8K cart)
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

def hex_digit_petscii(val):
    """Return PETSCII code for hex digit 0-F"""
    val = val & 0xF
    if val < 10:
        return 0x30 + val  # '0'-'9'
    else:
        return 0x01 + (val - 10)  # 'A'-'F' in PETSCII screen codes

code = []

# SEI
code.append(0x78)

# Set border to RED immediately (proves CRT is running)
code.append(0xA9); code.append(0x02)  # LDA #2 (red)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Set background to BLACK
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021

# Clear screen area (first 80 chars)
for i in range(40):
    code.append(0xA9); code.append(0x20)  # LDA #$20 (space)
    code.append(0x8D); code.append((0x0400 + i) & 0xFF); code.append((0x0400 + i) >> 8)  # STA $0400+i

# Print "SRAM DIAG" at top of screen
msg = "SRAM DIAG"
for i, ch in enumerate(msg):
    sc = ord(ch) - 0x40 if ch.isupper() else ord(ch)
    code.append(0xA9); code.append(sc)
    code.append(0x8D); code.append((0x0400 + i) & 0xFF); code.append((0x0400 + i) >> 8)

# Set color RAM for first line to WHITE
for i in range(40):
    code.append(0xA9); code.append(0x01)  # white
    code.append(0x8D); code.append((0xD800 + i) & 0xFF); code.append((0xD800 + i) >> 8)

# Enable SuperCPU registers: STA $D07E
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x7E); code.append(0xD0)

# Now read SuperRAM at $200000 using LDA long (absolute long = opcode $AF)
# LDA $200000 = AF 00 00 20
code.append(0xAF); code.append(0x00); code.append(0x00); code.append(0x20)

# Store result: this is the first byte at Doom entry ($78 = SEI expected)
# Display as border color
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020

# Also store the raw value
code.append(0x85); code.append(0xFB)  # STA $FB (ZP temp)

# Display hex value on screen at position 40 (second line)
# High nibble
code.append(0x4A)  # LSR
code.append(0x4A)  # LSR
code.append(0x4A)  # LSR
code.append(0x4A)  # LSR
code.append(0xAA)  # TAX
# Hex lookup table inline: use ORA trick
# if X < 10: digit = X + $30, else digit = X + $37
code.append(0x8A)  # TXA
code.append(0xC9); code.append(0x0A)  # CMP #$0A
code.append(0x90); code.append(0x04)  # BCC +4 (is digit)
code.append(0x18)  # CLC
code.append(0x69); code.append(0x37)  # ADC #$37
code.append(0x80); code.append(0x02)  # BRA +2
code.append(0x18)  # CLC
code.append(0x69); code.append(0x30)  # ADC #$30
# Convert ASCII to screen code: if >= $41, subtract $40
code.append(0xC9); code.append(0x41)  # CMP #$41
code.append(0x90); code.append(0x02)  # BCC +2
code.append(0xE9); code.append(0x40)  # SBC #$40
code.append(0x8D); code.append(0x28); code.append(0x04)  # STA $0428 (line 2, col 0)

# Low nibble
code.append(0xA5); code.append(0xFB)  # LDA $FB
code.append(0x29); code.append(0x0F)  # AND #$0F
code.append(0xAA)  # TAX
code.append(0x8A)  # TXA
code.append(0xC9); code.append(0x0A)  # CMP #$0A
code.append(0x90); code.append(0x04)  # BCC +4
code.append(0x18)  # CLC
code.append(0x69); code.append(0x37)  # ADC #$37
code.append(0x80); code.append(0x02)  # BRA +2
code.append(0x18)  # CLC
code.append(0x69); code.append(0x30)  # ADC #$30
code.append(0xC9); code.append(0x41)  # CMP #$41
code.append(0x90); code.append(0x02)  # BCC +2
code.append(0xE9); code.append(0x40)  # SBC #$40
code.append(0x8D); code.append(0x29); code.append(0x04)  # STA $0429 (line 2, col 1)

# Also read byte at $200001 and display
code.append(0xAF); code.append(0x01); code.append(0x00); code.append(0x20)  # LDA $200001
code.append(0x85); code.append(0xFB)  # STA $FB
# High nibble
code.append(0x4A); code.append(0x4A); code.append(0x4A); code.append(0x4A)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x2B); code.append(0x04)  # STA $042B
# Low nibble
code.append(0xA5); code.append(0xFB); code.append(0x29); code.append(0x0F)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x2C); code.append(0x04)  # STA $042C

# Read byte at $200002 and display
code.append(0xAF); code.append(0x02); code.append(0x00); code.append(0x20)  # LDA $200002
code.append(0x85); code.append(0xFB)
code.append(0x4A); code.append(0x4A); code.append(0x4A); code.append(0x4A)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x2E); code.append(0x04)
code.append(0xA5); code.append(0xFB); code.append(0x29); code.append(0x0F)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x2F); code.append(0x04)

# Read byte at $200003 and display  
code.append(0xAF); code.append(0x03); code.append(0x00); code.append(0x20)  # LDA $200003
code.append(0x85); code.append(0xFB)
code.append(0x4A); code.append(0x4A); code.append(0x4A); code.append(0x4A)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x31); code.append(0x04)
code.append(0xA5); code.append(0xFB); code.append(0x29); code.append(0x0F)
code.append(0xC9); code.append(0x0A); code.append(0x90); code.append(0x04)
code.append(0x18); code.append(0x69); code.append(0x37); code.append(0x80); code.append(0x02)
code.append(0x18); code.append(0x69); code.append(0x30)
code.append(0xC9); code.append(0x41); code.append(0x90); code.append(0x02); code.append(0xE9); code.append(0x40)
code.append(0x8D); code.append(0x32); code.append(0x04)

# Set color for second line
for i in range(10):
    code.append(0xA9); code.append(0x05)  # green
    code.append(0x8D); code.append((0xD828 + i) & 0xFF); code.append((0xD828 + i) >> 8)

# Print label "=$" before hex values
code.append(0xA9); code.append(0x3D)  # '='  screen code
code.append(0x8D); code.append(0x28 + 10); code.append(0x04)  # won't fit, let's skip

# Infinite loop with border color cycling to show we're alive
# JMP here
jmp_target = 0x8009 + len(code)
code.append(0x4C); code.append(jmp_target & 0xFF); code.append((jmp_target >> 8) & 0xFF)

print(f"Diagnostic CRT code size: {len(code)} bytes")
crt = make_crt(code, name="SRAM DIAG")
with open('crt/sram_diag.crt', 'wb') as f:
    f.write(crt)
print(f"Written crt/sram_diag.crt ({len(crt)} bytes)")

# Also make an MGL
mgl = '''<mistergamedescription>
<rbf>_Test/C64</rbf>
<file delay="5" type="f" index="1" path="/media/usb0/C64/doom.reu"/>
<file delay="5" type="f" index="1" path="/media/usb0/C64/sram_diag.crt"/>
</mistergamedescription>
'''
with open('crt/sram_diag.mgl', 'w') as f:
    f.write(mgl)
print("Written crt/sram_diag.mgl")
