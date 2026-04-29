#!/usr/bin/env python3
"""Minimal diagnostic CRT: border-color-only, no screen writes.

Stage colors:
  RED ($02)    = CRT code started
  GREEN ($05)  = VIC-II initialized  
  CYAN ($03)   = SuperCPU registers enabled ($D07E)
  WHITE ($01)  = About to read $200000
  (result)     = Border = LDA $200000 result & $0F (expect $08=orange for $78=SEI)
  
  If stuck on CYAN: $D07E hang
  If stuck on WHITE: LDA $200000 hung (SDRAM read fail)
  If shows ORANGE ($08): SuperRAM read returned $78 (correct!)
  If shows other color: SuperRAM data mismatch

After first read, also reads $200001-$200003, displays cycling pattern.
"""
import struct

def make_crt(code_bytes, name="MIN DIAG"):
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

code = []

# STAGE 1: RED - CRT started
code.append(0x78)  # SEI
code.append(0xA9); code.append(0x02)  # LDA #2 (red)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021 (both same so no distraction)

# STAGE 2: GREEN - VIC-II basic init
code.append(0xA9); code.append(0x1B)
code.append(0x8D); code.append(0x11); code.append(0xD0)  # STA $D011 (screen on)
code.append(0xA9); code.append(0x05)  # LDA #5 (green)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021

# STAGE 3: CYAN - enabling SuperCPU regs
code.append(0xA9); code.append(0x03)  # LDA #3 (cyan)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021
# Write to $D07E (enable SuperCPU registers)
code.append(0xA9); code.append(0x00)
code.append(0x8D); code.append(0x7E); code.append(0xD0)  # STA $D07E

# STAGE 4: WHITE - about to do LDA long
code.append(0xA9); code.append(0x01)  # LDA #1 (white)
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021

# THE KEY TEST: LDA $200000 (absolute long, opcode $AF)
# If this works, A = first byte of Doom ($78 = SEI)
code.append(0xAF); code.append(0x00); code.append(0x00); code.append(0x20)

# STAGE 5: Border = read result
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0x8D); code.append(0x21); code.append(0xD0)  # STA $D021

# Also save to ZP for later
code.append(0x85); code.append(0xFB)  # STA $FB

# Read bytes 1-3 and store to ZP
code.append(0xAF); code.append(0x01); code.append(0x00); code.append(0x20)  # LDA $200001
code.append(0x85); code.append(0xFC)
code.append(0xAF); code.append(0x02); code.append(0x00); code.append(0x20)  # LDA $200002
code.append(0x85); code.append(0xFD)
code.append(0xAF); code.append(0x03); code.append(0x00); code.append(0x20)  # LDA $200003
code.append(0x85); code.append(0xFE)

# Now cycle through the 4 values as border color in a visible loop
# This creates a distinctive flicker pattern we can see in screenshot
# Loop: display each byte for ~256 iterations, cycle forever
loop_start = 0x8009 + len(code)
# Byte 0
code.append(0xA5); code.append(0xFB)  # LDA $FB
code.append(0x8D); code.append(0x20); code.append(0xD0)  # STA $D020
code.append(0xA2); code.append(0x00)  # LDX #0
delay1 = 0x8009 + len(code)
code.append(0xCA)  # DEX
code.append(0xD0); code.append(0xFD)  # BNE -3 (self)

# Byte 1
code.append(0xA5); code.append(0xFC)
code.append(0x8D); code.append(0x20); code.append(0xD0)
code.append(0xA2); code.append(0x00)
delay2 = 0x8009 + len(code)
code.append(0xCA)
code.append(0xD0); code.append(0xFD)

# Byte 2
code.append(0xA5); code.append(0xFD)
code.append(0x8D); code.append(0x20); code.append(0xD0)
code.append(0xA2); code.append(0x00)
delay3 = 0x8009 + len(code)
code.append(0xCA)
code.append(0xD0); code.append(0xFD)

# Byte 3
code.append(0xA5); code.append(0xFE)
code.append(0x8D); code.append(0x20); code.append(0xD0)
code.append(0xA2); code.append(0x00)
delay4 = 0x8009 + len(code)
code.append(0xCA)
code.append(0xD0); code.append(0xFD)

# Jump back to start of cycle
code.append(0x4C); code.append(loop_start & 0xFF); code.append((loop_start >> 8) & 0xFF)

print(f"Minimal diagnostic code size: {len(code)} bytes")

crt = make_crt(code, name="MIN DIAG")
with open('crt/min_diag.crt', 'wb') as f:
    f.write(crt)
print(f"Written crt/min_diag.crt ({len(crt)} bytes)")

# MGL with REU preload
mgl = '<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/doom.reu"/>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/min_diag.crt"/>\n</mistergamedescription>\n'
with open('crt/min_diag.mgl', 'w') as f:
    f.write(mgl)
print("Written crt/min_diag.mgl")

# Also make a version WITHOUT REU preload (to test CRT-only behavior)
mgl2 = '<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/min_diag.crt"/>\n</mistergamedescription>\n'
with open('crt/min_diag_noreu.mgl', 'w') as f:
    f.write(mgl2)
print("Written crt/min_diag_noreu.mgl")
