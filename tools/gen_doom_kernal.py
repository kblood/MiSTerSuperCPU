#!/usr/bin/env python3
"""Generate a custom KERNAL ROM that auto-launches Doom at $200000.

The C64 KERNAL ROM is 8KB at $E000-$FFFF. We create a minimal ROM with:
- Reset vector ($FFFC-$FFFD) pointing to our launcher code
- NMI vector ($FFFA-$FFFB) pointing to RTI
- IRQ vector ($FFFE-$FFFF) pointing to RTI
- Launcher code at $FF00: disable interrupts, switch to native, JML $200000

Also includes a test variant that just changes border color + writes to screen
to verify the mechanism works before trying Doom.
"""
import struct

def make_kernal(launcher_code, name="doom_kernal"):
    """Create an 8KB KERNAL ROM with custom launcher at reset vector."""
    rom = bytearray(8192)  # $E000-$FFFF
    
    # Fill with NOP ($EA) for safety
    for i in range(len(rom)):
        rom[i] = 0xEA
    
    # RTI instruction at $FF80 (for NMI/IRQ vectors)
    rti_offset = 0xFF80 - 0xE000  # offset in ROM
    rom[rti_offset] = 0x40  # RTI
    
    # Launcher code at $FF00
    code_offset = 0xFF00 - 0xE000
    for i, b in enumerate(launcher_code):
        rom[code_offset + i] = b
    
    # Vectors at end of ROM:
    # $FFFA-$FFFB: NMI vector -> $FF80 (RTI)
    vec_offset = 0xFFFA - 0xE000
    rom[vec_offset] = 0x80     # NMI low
    rom[vec_offset + 1] = 0xFF # NMI high
    
    # $FFFC-$FFFD: RESET vector -> $FF00 (our launcher)
    rom[vec_offset + 2] = 0x00 # RESET low
    rom[vec_offset + 3] = 0xFF # RESET high
    
    # $FFFE-$FFFF: IRQ vector -> $FF80 (RTI)
    rom[vec_offset + 4] = 0x80 # IRQ low
    rom[vec_offset + 5] = 0xFF # IRQ high
    
    return bytes(rom)

# === Test launcher: changes border color and writes "TEST" to screen ===
test_code = []
test_code.append(0x78)  # SEI
test_code.append(0xA9); test_code.append(0x02)  # LDA #$02 (red)
test_code.append(0x8D); test_code.append(0x20); test_code.append(0xD0)  # STA $D020 (border)
test_code.append(0xA9); test_code.append(0x00)  # LDA #$00 (black)
test_code.append(0x8D); test_code.append(0x21); test_code.append(0xD0)  # STA $D021 (background)
# Write "TEST" to screen at $0400
test_code.append(0xA9); test_code.append(0x14)  # LDA #$14 (T)
test_code.append(0x8D); test_code.append(0x00); test_code.append(0x04)  # STA $0400
test_code.append(0xA9); test_code.append(0x05)  # LDA #$05 (E)
test_code.append(0x8D); test_code.append(0x01); test_code.append(0x04)  # STA $0401
test_code.append(0xA9); test_code.append(0x13)  # LDA #$13 (S)
test_code.append(0x8D); test_code.append(0x02); test_code.append(0x04)  # STA $0402
test_code.append(0xA9); test_code.append(0x14)  # LDA #$14 (T)
test_code.append(0x8D); test_code.append(0x03); test_code.append(0x04)  # STA $0403
# Set color RAM for those chars
test_code.append(0xA9); test_code.append(0x01)  # LDA #$01 (white)
test_code.append(0x8D); test_code.append(0x00); test_code.append(0xD8)  # STA $D800
test_code.append(0x8D); test_code.append(0x01); test_code.append(0xD8)  # STA $D801
test_code.append(0x8D); test_code.append(0x02); test_code.append(0xD8)  # STA $D802
test_code.append(0x8D); test_code.append(0x03); test_code.append(0xD8)  # STA $D803
# Infinite loop
loop_addr = 0xFF00 + len(test_code)
test_code.append(0x4C)
test_code.append(loop_addr & 0xFF)
test_code.append((loop_addr >> 8) & 0xFF)

test_rom = make_kernal(test_code)
with open('crt/test_kernal.rom', 'wb') as f:
    f.write(test_rom)
print(f"Written crt/test_kernal.rom ({len(test_rom)} bytes) - border=red, 'TEST' on screen")

# === Doom launcher: minimal init + JML $200000 ===
doom_code = []
doom_code.append(0x78)  # SEI

# Initialize VIC-II basics (screen on, default mode)
doom_code.append(0xA9); doom_code.append(0x1B)  # LDA #$1B
doom_code.append(0x8D); doom_code.append(0x11); doom_code.append(0xD0)  # STA $D011

# Disable CIA2 NMIs
doom_code.append(0xA9); doom_code.append(0x7F)  # LDA #$7F
doom_code.append(0x8D); doom_code.append(0x0D); doom_code.append(0xDD)  # STA $DD0D
doom_code.append(0xAD); doom_code.append(0x0D); doom_code.append(0xDD)  # LDA $DD0D (ack)

# Disable CIA1 IRQs
doom_code.append(0xA9); doom_code.append(0x7F)  # LDA #$7F
doom_code.append(0x8D); doom_code.append(0x0D); doom_code.append(0xDC)  # STA $DC0D
doom_code.append(0xAD); doom_code.append(0x0D); doom_code.append(0xDC)  # LDA $DC0D (ack)

# Disable VIC IRQs
doom_code.append(0xA9); doom_code.append(0x00)  # LDA #$00
doom_code.append(0x8D); doom_code.append(0x1A); doom_code.append(0xD0)  # STA $D01A

# RAM visible everywhere (no BASIC/KERNAL ROM): write $35 to $01
doom_code.append(0xA9); doom_code.append(0x35)  # LDA #$35
doom_code.append(0x85); doom_code.append(0x01)  # STA $01

# Enable SuperCPU registers: STA $D07E
doom_code.append(0xA9); doom_code.append(0x00)  # LDA #$00
doom_code.append(0x8D); doom_code.append(0x7E); doom_code.append(0xD0)  # STA $D07E

# Switch to native mode: CLC + XCE
doom_code.append(0x18)  # CLC
doom_code.append(0xFB)  # XCE

# 16-bit registers: REP #$30
doom_code.append(0xC2); doom_code.append(0x30)  # REP #$30

# Set direct page to 0: LDA #$0000, TCD
doom_code.append(0xA9); doom_code.append(0x00); doom_code.append(0x00)  # LDA #$0000
doom_code.append(0x5B)  # TCD

# Set stack: LDA #$01FF, TCS
doom_code.append(0xA9); doom_code.append(0xFF); doom_code.append(0x01)  # LDA #$01FF
doom_code.append(0x1B)  # TCS

# Back to 8-bit accumulator: SEP #$20
doom_code.append(0xE2); doom_code.append(0x20)  # SEP #$20

# Set data bank to 0: LDA #$00, PHA, PLB
doom_code.append(0xA9); doom_code.append(0x00)  # LDA #$00
doom_code.append(0x48)  # PHA
doom_code.append(0xAB)  # PLB

# JML $200000 - jump to Doom
doom_code.append(0x5C); doom_code.append(0x00); doom_code.append(0x00); doom_code.append(0x20)

doom_rom = make_kernal(doom_code)
with open('crt/doom_kernal.rom', 'wb') as f:
    f.write(doom_rom)
print(f"Written crt/doom_kernal.rom ({len(doom_rom)} bytes) - direct JML $200000")

# === 1MHz Doom launcher (same but forces 1MHz first) ===
doom_1mhz_code = list(doom_code)  # copy
# Insert STA $D07A before CLC/XCE (force 1MHz)
# Find the CLC (0x18) position
clc_idx = doom_1mhz_code.index(0x18)
# Insert STA $D07A before CLC
insert = [0x8D, 0x7A, 0xD0]  # STA $D07A
for i, b in enumerate(insert):
    doom_1mhz_code.insert(clc_idx + i, b)

doom_1mhz_rom = make_kernal(doom_1mhz_code)
with open('crt/doom_1mhz_kernal.rom', 'wb') as f:
    f.write(doom_1mhz_rom)
print(f"Written crt/doom_1mhz_kernal.rom ({len(doom_1mhz_rom)} bytes) - 1MHz + JML $200000")

print("\nTo load: mbc load_rom 3 <file.rom>  (slot 3 = FC8 = KERNAL ROM)")
print("Note: Loading KERNAL ROM triggers automatic reset")
