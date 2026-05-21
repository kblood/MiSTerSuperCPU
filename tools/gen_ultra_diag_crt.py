#!/usr/bin/env python3
"""Ultra-simple diagnostic CRT: reads $200000 and displays result as steady border.

No cycling, no screen writes. Just:
1. RED border (CRT started)
2. Enable $D07E 
3. LDA $200000, store result as border+background
4. Infinite JMP (stays on that color forever)

Expected: ORANGE border ($08) if Doom data ($78=SEI) is at $200000
"""
import struct

def make_crt(code_bytes, name="ULTRA DIAG"):
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
    rom[9 + len(code_bytes)] = 0x40
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

# === Test A: Read $200000, show as border ===
code_a = []
code_a.append(0x78)  # SEI
# RED border+bg first
code_a.append(0xA9); code_a.append(0x02)
code_a.append(0x8D); code_a.append(0x20); code_a.append(0xD0)  # border=red
code_a.append(0x8D); code_a.append(0x21); code_a.append(0xD0)  # bg=red
# Enable SuperCPU: STA $D07E
code_a.append(0xA9); code_a.append(0x00)
code_a.append(0x8D); code_a.append(0x7E); code_a.append(0xD0)
# GREEN border (passed D07E)
code_a.append(0xA9); code_a.append(0x05)
code_a.append(0x8D); code_a.append(0x20); code_a.append(0xD0)
code_a.append(0x8D); code_a.append(0x21); code_a.append(0xD0)
# LDA $200000 (absolute long)
code_a.append(0xAF); code_a.append(0x00); code_a.append(0x00); code_a.append(0x20)
# Store to border AND background
code_a.append(0x8D); code_a.append(0x20); code_a.append(0xD0)
code_a.append(0x8D); code_a.append(0x21); code_a.append(0xD0)
# Also store to $0400 (first screen char) so we can see raw value
code_a.append(0x8D); code_a.append(0x00); code_a.append(0x04)
# Infinite loop
jmp = 0x8009 + len(code_a)
code_a.append(0x4C); code_a.append(jmp & 0xFF); code_a.append((jmp >> 8) & 0xFF)

crt_a = make_crt(code_a, "READ 200000")
with open('crt/read_200000.crt', 'wb') as f: f.write(crt_a)
print("Written crt/read_200000.crt (%d bytes code)" % len(code_a))

# === Test B: Read $000400 (screen RAM in bank 0), show as border ===
# This tests if LDA absolute long works at ALL
code_b = []
code_b.append(0x78)  # SEI
# First write a KNOWN value to $0400
code_b.append(0xA9); code_b.append(0x42)  # LDA #$42
code_b.append(0x8D); code_b.append(0x00); code_b.append(0x04)  # STA $0400
# Now read it back using LDA LONG (bank 0)
code_b.append(0xAF); code_b.append(0x00); code_b.append(0x04); code_b.append(0x00)  # LDA $000400
# If LDA long works: A=$42, border=$42&$0F=$02=RED
# If LDA long fails: A=??, border=??
code_b.append(0x8D); code_b.append(0x20); code_b.append(0xD0)  # border = result
code_b.append(0x8D); code_b.append(0x21); code_b.append(0xD0)  # bg = result
jmp = 0x8009 + len(code_b)
code_b.append(0x4C); code_b.append(jmp & 0xFF); code_b.append((jmp >> 8) & 0xFF)

crt_b = make_crt(code_b, "LDA LONG TEST")
with open('crt/lda_long_test.crt', 'wb') as f: f.write(crt_b)
print("Written crt/lda_long_test.crt (%d bytes code)" % len(code_b))

# === Test C: Just set border to YELLOW and loop (simplest CRT test) ===
code_c = []
code_c.append(0x78)  # SEI
code_c.append(0xA9); code_c.append(0x07)  # LDA #7 (yellow)
code_c.append(0x8D); code_c.append(0x20); code_c.append(0xD0)
code_c.append(0x8D); code_c.append(0x21); code_c.append(0xD0)
jmp = 0x8009 + len(code_c)
code_c.append(0x4C); code_c.append(jmp & 0xFF); code_c.append((jmp >> 8) & 0xFF)

crt_c = make_crt(code_c, "YELLOW TEST")
with open('crt/yellow_test.crt', 'wb') as f: f.write(crt_c)
print("Written crt/yellow_test.crt (%d bytes code)" % len(code_c))

# MGLs - all standalone (no REU)
for name, crt_name in [('read_200000', 'read_200000'), ('lda_long_test', 'lda_long_test'), ('yellow_test', 'yellow_test')]:
    mgl = '<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/%s.crt"/>\n</mistergamedescription>\n' % crt_name
    with open('crt/%s.mgl' % name, 'w') as f: f.write(mgl)
    print("Written crt/%s.mgl" % name)

# Also REU + read_200000
mgl_reu = '<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/doom.reu"/>\n<file delay="5" type="f" index="1" path="/media/usb0/C64/read_200000.crt"/>\n</mistergamedescription>\n'
with open('crt/read_200000_reu.mgl', 'w') as f: f.write(mgl_reu)
print("Written crt/read_200000_reu.mgl")
