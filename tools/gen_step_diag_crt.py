#!/usr/bin/env python3
"""Step-by-step diagnostic CRT to isolate LDA long hang.

Each test step changes border color to mark progress.
If CPU hangs, the border stays at the last successful step's color.

Test A: Progressive addressing modes
  $01 = started (SEI done)
  $02 = LDA #imm works
  $03 = STA $D020 works (border was set)
  $04 = STA abs works ($0400 written)
  $05 = LDA abs works ($0400 read back)
  $06 = about to try LDA long bank $00
  $07 = LDA long bank $00 works!!
  $08 = about to try LDA long bank $20
  $09 = LDA long bank $20 works!!
  $0A = final success

Test B: Just LDA absolute long to bank $00 (minimal)
  $02 = started
  $05 = about to LDA long
  HANG = stays $05 if LDA long hangs
  $07 = LDA long succeeded (border shows read data)

Test C: NOP sled + LDA long (test if timing matters)
"""
import struct

def make_crt(code_bytes, name="DIAG"):
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

def set_border(code, color):
    """LDA #color, STA $D020"""
    code.append(0xA9); code.append(color)
    code.append(0x8D); code.append(0x20); code.append(0xD0)

def set_bg(code, color):
    """LDA #color, STA $D021"""
    code.append(0xA9); code.append(color)
    code.append(0x8D); code.append(0x21); code.append(0xD0)

def infinite_loop(code):
    jmp = 0x8009 + len(code)
    code.append(0x4C); code.append(jmp & 0xFF); code.append((jmp >> 8) & 0xFF)

def nops(code, n):
    for _ in range(n):
        code.append(0xEA)

# ==========================================================================
# Test A: Progressive test of all addressing modes
# ==========================================================================
code_a = []
code_a.append(0x78)  # SEI

# Step 1: border = $01 (white) - we're alive
set_border(code_a, 0x01)

# Step 2: border = $02 (red) - immediate addressing works
set_border(code_a, 0x02)

# Step 3: Write known value to $0400
code_a.append(0xA9); code_a.append(0x42)  # LDA #$42
code_a.append(0x8D); code_a.append(0x00); code_a.append(0x04)  # STA $0400
set_border(code_a, 0x03)  # cyan - STA abs works

# Step 4: Read back with LDA absolute (NOT long) - $AD
code_a.append(0xAD); code_a.append(0x00); code_a.append(0x04)  # LDA $0400
# A should be $42. Compare by storing to screen
code_a.append(0x8D); code_a.append(0x00); code_a.append(0x04)  # STA $0400 (write back)
set_border(code_a, 0x04)  # purple - LDA abs works

# Step 5: NOP sled before long addressing (gives bus time to settle)
nops(code_a, 16)
set_border(code_a, 0x05)  # green - about to try LDA long bank $00

# Step 6: LDA absolute long bank $00 - $AF $00 $04 $00
code_a.append(0xAF)  # LDA long
code_a.append(0x00)  # addr low = $00
code_a.append(0x04)  # addr high = $04
code_a.append(0x00)  # bank = $00
# IF WE GET HERE: A = whatever is at $00:$0400 (should be $42)
set_border(code_a, 0x07)  # yellow - LDA long bank 00 works!

# Step 7: Write A to $0401 so we can see what was read
code_a.append(0x8D); code_a.append(0x01); code_a.append(0x04)  # STA $0401

# Step 8: About to try bank $20
set_border(code_a, 0x08)  # orange - about to LDA long bank $20
nops(code_a, 16)

# Step 9: LDA absolute long bank $20 - $AF $00 $00 $20
code_a.append(0xAF)  # LDA long
code_a.append(0x00)  # addr low
code_a.append(0x00)  # addr high
code_a.append(0x20)  # bank = $20

# IF WE GET HERE: A = whatever is at $20:$0000
set_border(code_a, 0x0D)  # light green - LDA long bank 20 works!
code_a.append(0x8D); code_a.append(0x02); code_a.append(0x04)  # STA $0402 (show value)

# Final: store result in border and loop
code_a.append(0x8D); code_a.append(0x20); code_a.append(0xD0)  # border = read value
code_a.append(0x8D); code_a.append(0x21); code_a.append(0xD0)  # bg = read value
infinite_loop(code_a)

crt_a = make_crt(code_a, "STEP DIAG A")
with open('crt/step_diag_a.crt', 'wb') as f: f.write(crt_a)
print("Written crt/step_diag_a.crt (%d bytes code)" % len(code_a))

# ==========================================================================
# Test B: Minimal LDA long bank $00 only (simplest possible test)
# ==========================================================================
code_b = []
code_b.append(0x78)  # SEI
set_border(code_b, 0x02)  # red = started
set_bg(code_b, 0x00)      # black bg

# Write $42 to $0400
code_b.append(0xA9); code_b.append(0x42)
code_b.append(0x8D); code_b.append(0x00); code_b.append(0x04)

set_border(code_b, 0x05)  # green = about to try LDA long

# LDA absolute long from $000400
code_b.append(0xAF); code_b.append(0x00); code_b.append(0x04); code_b.append(0x00)

# If we get here, show result as border color
# A should be $42, border = $42 & $0F = $02 = red
code_b.append(0x8D); code_b.append(0x20); code_b.append(0xD0)  # border = A
set_bg(code_b, 0x00)  # bg stays black so border is visible
infinite_loop(code_b)

crt_b = make_crt(code_b, "LDA LONG B00")
with open('crt/lda_long_b00.crt', 'wb') as f: f.write(crt_b)
print("Written crt/lda_long_b00.crt (%d bytes code)" % len(code_b))

# ==========================================================================
# Test C: Minimal LDA absolute (NOT long) - control test
# ==========================================================================
code_c = []
code_c.append(0x78)  # SEI
set_border(code_c, 0x02)  # red = started
set_bg(code_c, 0x00)

# Write $42 to $0400
code_c.append(0xA9); code_c.append(0x42)
code_c.append(0x8D); code_c.append(0x00); code_c.append(0x04)

set_border(code_c, 0x05)  # green = about to try LDA abs

# LDA absolute (NOT long) from $0400 - this should definitely work
code_c.append(0xAD); code_c.append(0x00); code_c.append(0x04)

# A = $42, border = $42 & $0F = $02 = red
code_c.append(0x8D); code_c.append(0x20); code_c.append(0xD0)
set_bg(code_c, 0x00)
infinite_loop(code_c)

crt_c = make_crt(code_c, "LDA ABS CTL")
with open('crt/lda_abs_control.crt', 'wb') as f: f.write(crt_c)
print("Written crt/lda_abs_control.crt (%d bytes code)" % len(code_c))

# ==========================================================================
# Test D: LDA long bank $00 with MANY NOP sleds around it
# (tests if the issue is timing-related)
# ==========================================================================
code_d = []
code_d.append(0x78)  # SEI
set_border(code_d, 0x02)  # red

# Write $42 to $0400
code_d.append(0xA9); code_d.append(0x42)
code_d.append(0x8D); code_d.append(0x00); code_d.append(0x04)

# 64 NOPs
nops(code_d, 64)
set_border(code_d, 0x05)  # green = about to try

# 32 more NOPs
nops(code_d, 32)

# LDA long bank $00
code_d.append(0xAF); code_d.append(0x00); code_d.append(0x04); code_d.append(0x00)

# 32 NOPs after
nops(code_d, 32)

# Show result
code_d.append(0x8D); code_d.append(0x20); code_d.append(0xD0)
set_bg(code_d, 0x00)
infinite_loop(code_d)

crt_d = make_crt(code_d, "LDA LONG NOP")
with open('crt/lda_long_nop.crt', 'wb') as f: f.write(crt_d)
print("Written crt/lda_long_nop.crt (%d bytes code)" % len(code_d))

# ==========================================================================
# Generate MGL files for each test
# ==========================================================================
tests = ['step_diag_a', 'lda_long_b00', 'lda_abs_control', 'lda_long_nop']
for t in tests:
    mgl = '<mistergamedescription>\n'
    mgl += '<rbf>_Test/C64</rbf>\n'
    mgl += '<file delay="5" type="f" index="1" path="/media/usb0/C64/%s.crt"/>\n' % t
    mgl += '</mistergamedescription>\n'
    with open('crt/%s.mgl' % t, 'w') as f: f.write(mgl)
    print("Written crt/%s.mgl" % t)

print("\n=== Test Plan ===")
print("1. lda_abs_control.mgl: Control test (LDA $0400, NOT long)")
print("   Expected: GREEN->RED border (green=started, red=$42&$0F)")
print("   If stays GREEN: even basic LDA absolute is broken!")
print()
print("2. lda_long_b00.mgl: LDA long to bank $00 only")
print("   Expected: GREEN->RED border")
print("   If stays GREEN: LDA long ($AF) is broken for bank $00")
print()
print("3. lda_long_nop.mgl: LDA long with NOP sleds")
print("   Expected: GREEN->RED border")
print("   If stays GREEN but b00 works without NOPs: timing issue")
print()
print("4. step_diag_a.mgl: Full progressive test")
print("   Border color shows last successful step:")
print("   $01=alive $02=imm $03=STA_abs $04=LDA_abs")
print("   $05=pre_long_b00 $07=long_b00_ok $08=pre_long_b20 $0D=long_b20_ok")
