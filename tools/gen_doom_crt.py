#!/usr/bin/env python3
"""Generate a CRT cartridge that auto-boots and jumps to $200000 (Doom in SuperRAM).

CRT format: standard C64 cartridge image
- C64 CARTRIDGE header
- CHIP packet with 8K ROM at $8000
- Contains CBM80 magic for auto-boot
- Code: SEI, disable NMI, switch to native mode, JML $200000
"""
import struct

def make_crt(code_bytes, name="DOOM LAUNCHER", hw_type=0):
    """Create a CRT file with auto-boot code."""
    
    # Pad code to 8K
    rom = bytearray(8192)
    
    # Reset vector at $8000-$8001 -> $8009 (after magic)
    code_start = 0x8009
    rom[0] = code_start & 0xFF        # $8000: reset vector low
    rom[1] = (code_start >> 8) & 0xFF  # $8001: reset vector high
    
    # NMI vector at $8002-$8003 -> RTI stub
    rti_addr = 0x8009 + len(code_bytes)
    rom[2] = rti_addr & 0xFF          # $8002: NMI vector low  
    rom[3] = (rti_addr >> 8) & 0xFF   # $8003: NMI vector high
    
    # CBM80 magic at $8004-$8008
    rom[4] = 0xC3  # 'C'
    rom[5] = 0xC2  # 'B'
    rom[6] = 0xCD  # 'M'
    rom[7] = 0x38  # '8'
    rom[8] = 0x30  # '0'
    
    # Code at $8009+
    for i, b in enumerate(code_bytes):
        rom[9 + i] = b
    
    # RTI instruction after code
    rom[9 + len(code_bytes)] = 0x40  # RTI
    
    # CRT Header (64 bytes)
    header = bytearray(64)
    # Signature: "C64 CARTRIDGE   " (16 bytes)
    sig = b'C64 CARTRIDGE   '
    header[0:16] = sig
    # Header length (big-endian 32-bit) = 0x40 = 64
    struct.pack_into('>I', header, 16, 64)
    # CRT version: 1.0
    struct.pack_into('>H', header, 20, 0x0100)
    # Hardware type (big-endian 16-bit): 0 = normal cartridge
    struct.pack_into('>H', header, 22, hw_type)
    # EXROM line: 0 (directly active)
    header[24] = 0
    # GAME line: 1 (8K mode: ROML at $8000-$9FFF)
    header[25] = 1
    # Reserved (6 bytes)
    # Name (32 bytes, padded with zeros)
    name_bytes = name.encode('ascii')[:32]
    header[32:32+len(name_bytes)] = name_bytes
    
    # CHIP packet
    chip = bytearray(16)
    # Signature: "CHIP"
    chip[0:4] = b'CHIP'
    # Total packet length (big-endian 32-bit) = 16 header + 8192 data
    struct.pack_into('>I', chip, 4, 16 + 8192)
    # Chip type: 0 = ROM
    struct.pack_into('>H', chip, 8, 0)
    # Bank number: 0
    struct.pack_into('>H', chip, 10, 0)
    # Starting load address (big-endian 16-bit): $8000
    struct.pack_into('>H', chip, 12, 0x8000)
    # ROM size (big-endian 16-bit): $2000 = 8192
    struct.pack_into('>H', chip, 14, 0x2000)
    
    return bytes(header) + bytes(chip) + bytes(rom)


# === Doom Launcher Code ===
# This runs at $8009 after C64 KERNAL detects CBM80 magic
code = []

# SEI - disable interrupts
code.append(0x78)

# Disable CIA NMIs
code.append(0xA9); code.append(0x7F)  # LDA #$7F
code.append(0x8D); code.append(0x0D); code.append(0xDD)  # STA $DD0D
code.append(0xAD); code.append(0x0D); code.append(0xDD)  # LDA $DD0D (ack)

# Disable CIA1 IRQs  
code.append(0xA9); code.append(0x7F)  # LDA #$7F
code.append(0x8D); code.append(0x0D); code.append(0xDC)  # STA $DC0D
code.append(0xAD); code.append(0x0D); code.append(0xDC)  # LDA $DC0D (ack)

# Disable VIC IRQs
code.append(0xA9); code.append(0x00)  # LDA #$00
code.append(0x8D); code.append(0x1A); code.append(0xD0)  # STA $D01A

# Enable SuperCPU registers: STA $D07E
code.append(0xA9); code.append(0x00)  # LDA #$00
code.append(0x8D); code.append(0x7E); code.append(0xD0)  # STA $D07E

# Switch to native mode: CLC + XCE
code.append(0x18)  # CLC
code.append(0xFB)  # XCE

# Set 16-bit accumulator and index: REP #$30
code.append(0xC2); code.append(0x30)  # REP #$30

# Set direct page to 0: LDA #$0000, TCD
code.append(0xA9); code.append(0x00); code.append(0x00)  # LDA #$0000
code.append(0x5B)  # TCD

# Set stack: LDA #$01FF, TCS  
code.append(0xA9); code.append(0xFF); code.append(0x01)  # LDA #$01FF
code.append(0x1B)  # TCS

# SEP #$20 - back to 8-bit accumulator
code.append(0xE2); code.append(0x20)  # SEP #$20

# Set data bank to 0: LDA #$00, PHA, PLB
code.append(0xA9); code.append(0x00)  # LDA #$00
code.append(0x48)  # PHA
code.append(0xAB)  # PLB

# JML $200000 - jump to Doom
code.append(0x5C); code.append(0x00); code.append(0x00); code.append(0x20)  # JML $200000

print(f"Code size: {len(code)} bytes")
print(f"Code bytes: {' '.join(f'{b:02X}' for b in code)}")

# Generate CRT
crt_data = make_crt(code)

with open('crt/doom_launcher.crt', 'wb') as f:
    f.write(crt_data)
print(f"Written crt/doom_launcher.crt ({len(crt_data)} bytes)")

# Also generate a minimal version that doesn't switch to native mode
# (for testing if the CRT mechanism works at all)
test_code = []
# Just show something on screen to prove CRT auto-boot works
# LDA #$01, STA $D020 (change border to white)  
test_code.append(0xA9); test_code.append(0x01)  # LDA #$01
test_code.append(0x8D); test_code.append(0x20); test_code.append(0xD0)  # STA $D020
# Write 'D','O','O','M' to screen RAM at $0400
test_code.append(0xA9); test_code.append(0x04)  # LDA #$04 (D)
test_code.append(0x8D); test_code.append(0x00); test_code.append(0x04)  # STA $0400
test_code.append(0xA9); test_code.append(0x0F)  # LDA #$0F (O)
test_code.append(0x8D); test_code.append(0x01); test_code.append(0x04)  # STA $0401
test_code.append(0xA9); test_code.append(0x0F)  # LDA #$0F (O)
test_code.append(0x8D); test_code.append(0x02); test_code.append(0x04)  # STA $0402
test_code.append(0xA9); test_code.append(0x0D)  # LDA #$0D (M)
test_code.append(0x8D); test_code.append(0x03); test_code.append(0x04)  # STA $0403
# Infinite loop
test_code.append(0x4C)  # JMP $8009+len(test_code)-3
loop_addr = 0x8009 + len(test_code) - 3
test_code.append(loop_addr & 0xFF)
test_code.append((loop_addr >> 8) & 0xFF)

crt_test = make_crt(test_code, name="CRT BOOT TEST")
with open('crt/boot_test.crt', 'wb') as f:
    f.write(crt_test)
print(f"Written crt/boot_test.crt ({len(crt_test)} bytes)")

# Also make a version that does a 1MHz Doom launch (safe, no turbo)
code_1mhz = []
code_1mhz.append(0x78)  # SEI

# Disable NMIs
code_1mhz.append(0xA9); code_1mhz.append(0x7F)  # LDA #$7F
code_1mhz.append(0x8D); code_1mhz.append(0x0D); code_1mhz.append(0xDD)  # STA $DD0D
code_1mhz.append(0xAD); code_1mhz.append(0x0D); code_1mhz.append(0xDD)  # LDA $DD0D

# Disable CIA1 IRQs  
code_1mhz.append(0xA9); code_1mhz.append(0x7F)  # LDA #$7F
code_1mhz.append(0x8D); code_1mhz.append(0x0D); code_1mhz.append(0xDC)  # STA $DC0D
code_1mhz.append(0xAD); code_1mhz.append(0x0D); code_1mhz.append(0xDC)  # LDA $DC0D

# Disable VIC IRQs
code_1mhz.append(0xA9); code_1mhz.append(0x00)  # LDA #$00
code_1mhz.append(0x8D); code_1mhz.append(0x1A); code_1mhz.append(0xD0)  # STA $D01A

# Enable SuperCPU registers
code_1mhz.append(0xA9); code_1mhz.append(0x00)  # LDA #$00 
code_1mhz.append(0x8D); code_1mhz.append(0x7E); code_1mhz.append(0xD0)  # STA $D07E

# Force 1MHz: STA $D07A
code_1mhz.append(0x8D); code_1mhz.append(0x7A); code_1mhz.append(0xD0)  # STA $D07A

# Switch to native mode
code_1mhz.append(0x18)  # CLC
code_1mhz.append(0xFB)  # XCE

# REP #$30
code_1mhz.append(0xC2); code_1mhz.append(0x30)

# TCD (DP=0)
code_1mhz.append(0xA9); code_1mhz.append(0x00); code_1mhz.append(0x00)
code_1mhz.append(0x5B)

# TCS (SP=$01FF)
code_1mhz.append(0xA9); code_1mhz.append(0xFF); code_1mhz.append(0x01)
code_1mhz.append(0x1B)

# SEP #$20
code_1mhz.append(0xE2); code_1mhz.append(0x20)

# DBR=0
code_1mhz.append(0xA9); code_1mhz.append(0x00)
code_1mhz.append(0x48)
code_1mhz.append(0xAB)

# JML $200000
code_1mhz.append(0x5C); code_1mhz.append(0x00); code_1mhz.append(0x00); code_1mhz.append(0x20)

crt_1mhz = make_crt(code_1mhz, name="DOOM 1MHZ")
with open('crt/doom_1mhz.crt', 'wb') as f:
    f.write(crt_1mhz)
print(f"Written crt/doom_1mhz.crt ({len(crt_1mhz)} bytes)")
