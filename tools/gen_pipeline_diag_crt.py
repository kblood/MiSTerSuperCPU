#!/usr/bin/env python3
"""Generate diagnostic CRTs to isolate the 4-byte instruction hang.

Test 1: 1MHz mode - forces 1MHz (STA $D07A) before LDA long.
  Eliminates turbo/cache/BRAM pipeline: only SDRAM enableCpu at CPUC.
  If WORKS: bug is in turbo pipeline. If HANGS: bug is in core CPU/MCode/SDRAM.

Test 2: RAM execution - copies LDA long test to RAM at $0500, executes from there.
  Program fetches from RAM go through BRAM (fast path) instead of SDRAM/buslogic.
  If WORKS: bug is in SDRAM/buslogic ROML data delivery.
  If HANGS: bug is in CPU core or BRAM enable logic.

Test 3: Pre-cached - reads operand byte addresses with LDA abs before executing LDA long.
  Forces cache fills for the operand bytes. If cache hits work, $AF completes.
  If WORKS: bug is in SDRAM pipeline for uncached ROML reads.

Color codes: GREEN=pre-test, RED=pass, YELLOW=wrong data, GREEN stays=hung
"""

import struct, os

def make_crt(name, code, base=0x8009):
    """Build an 8K CRT with auto-boot (CBM80 magic)."""
    rom = bytearray(8192)
    # Reset vector -> $8009 (code entry)
    rom[0] = 0x09  # low byte of reset vector
    rom[1] = 0x80  # high byte
    # CBM80 magic at $8004
    rom[4] = 0xC3; rom[5] = 0xC2; rom[6] = 0xCD; rom[7] = 0x38; rom[8] = 0x30
    # Copy code
    offset = base - 0x8000
    for i, b in enumerate(code):
        rom[offset + i] = b

    # CRT header
    hdr = bytearray(64)
    hdr[0:16] = b'C64 CARTRIDGE   '
    struct.pack_into('>I', hdr, 16, 64)      # header length
    struct.pack_into('>H', hdr, 20, 0x0100)  # version
    struct.pack_into('>H', hdr, 22, 0)       # type: normal
    hdr[24] = 0  # EXROM=0
    hdr[25] = 1  # GAME=1 (8K mode)
    name_bytes = name.encode('ascii')[:32]
    hdr[32:32+len(name_bytes)] = name_bytes

    # CHIP packet
    chip = bytearray(16)
    chip[0:4] = b'CHIP'
    struct.pack_into('>I', chip, 4, 16 + len(rom))
    struct.pack_into('>H', chip, 8, 0)       # ROM
    struct.pack_into('>H', chip, 10, 0)      # bank 0
    struct.pack_into('>H', chip, 12, 0x8000) # load address
    struct.pack_into('>H', chip, 14, len(rom))

    return bytes(hdr) + bytes(chip) + bytes(rom)

def make_mgl(crt_filename):
    """Generate MGL launcher file."""
    return f'''<mistergamedescription>
    <rbf>_Test/C64</rbf>
    <file delay="1" type="f" index="1" path="../../usb0/C64/{crt_filename}"/>
</mistergamedescription>
'''

def gen_test1_1mhz():
    """Test 1: Force 1MHz mode, then execute LDA long."""
    code = bytearray()
    # First: prime BRAM with known value (while still in turbo mode)
    code += bytes([0xA9, 0x42])       # LDA #$42
    code += bytes([0x8D, 0x00, 0x04]) # STA $0400

    # Force 1MHz mode: STA $D07A
    code += bytes([0x8D, 0x7A, 0xD0]) # STA $D07A (value doesn't matter, just the write)

    # NOP sled for pipeline to settle (16 NOPs)
    for _ in range(16):
        code += bytes([0xEA])

    # Green border (pre-test marker)
    code += bytes([0xA9, 0x05])       # LDA #$05
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020

    # THE CRITICAL TEST: LDA long at 1MHz
    code += bytes([0xAF, 0x00, 0x04, 0x00])  # LDA $000400

    # If we get here, LDA long completed!
    code += bytes([0xC9, 0x42])       # CMP #$42
    code += bytes([0xD0, 0x07])       # BNE wrong_data

    # PASS: red border
    code += bytes([0xA9, 0x02])       # LDA #$02
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    code += bytes([0x4C])             # JMP (to self-3)
    here = len(code) - 1
    code += bytes([(0x8009 + here - 2) & 0xFF, ((0x8009 + here - 2) >> 8) & 0xFF])

    # WRONG DATA: yellow border
    code += bytes([0xA9, 0x07])       # LDA #$07
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    code += bytes([0x4C])             # JMP (to self-3)
    here2 = len(code) - 1
    code += bytes([(0x8009 + here2 - 2) & 0xFF, ((0x8009 + here2 - 2) >> 8) & 0xFF])

    return code

def gen_test2_ram_exec():
    """Test 2: Copy test code to RAM, execute from there."""
    # The test routine that will be copied to $0500
    test_routine = bytearray()
    test_base = 0x0500
    # Store known value to $0600
    test_routine += bytes([0xA9, 0x55])       # LDA #$55
    test_routine += bytes([0x8D, 0x00, 0x06]) # STA $0600
    # Green border
    test_routine += bytes([0xA9, 0x05])       # LDA #$05
    test_routine += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    # LDA long from $000600
    test_routine += bytes([0xAF, 0x00, 0x06, 0x00])  # LDA $000600
    # Check result
    test_routine += bytes([0xC9, 0x55])       # CMP #$55
    test_routine += bytes([0xD0, 0x07])       # BNE wrong
    # PASS: red border
    test_routine += bytes([0xA9, 0x02])       # LDA #$02
    test_routine += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    addr = test_base + len(test_routine) - 3
    test_routine += bytes([0x4C, addr & 0xFF, (addr >> 8) & 0xFF])
    # WRONG: yellow border
    test_routine += bytes([0xA9, 0x07])       # LDA #$07
    test_routine += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    addr2 = test_base + len(test_routine) - 3
    test_routine += bytes([0x4C, addr2 & 0xFF, (addr2 >> 8) & 0xFF])

    # CRT boot code: copy test_routine to $0500, then JMP $0500
    code = bytearray()
    # LDX #0; loop: LDA $xxxx,X; STA $0500,X; INX; CPX #len; BNE loop; JMP $0500
    # But we can't use LDA abs,X easily with CRT addresses. Use a simpler approach:
    # Inline the bytes using LDA # / STA abs for each byte.
    for i, b in enumerate(test_routine):
        code += bytes([0xA9, b])                          # LDA #byte
        addr_lo = (0x0500 + i) & 0xFF
        addr_hi = ((0x0500 + i) >> 8) & 0xFF
        code += bytes([0x8D, addr_lo, addr_hi])           # STA $0500+i

    # Jump to the test routine in RAM
    code += bytes([0x4C, 0x00, 0x05])  # JMP $0500

    return code

def gen_test3_precached():
    """Test 3: Pre-read operand byte addresses to fill cache, then LDA long."""
    code = bytearray()
    base = 0x8009

    # Prime BRAM with known value
    code += bytes([0xA9, 0x42])       # LDA #$42
    code += bytes([0x8D, 0x00, 0x04]) # STA $0400

    # Calculate where the AF instruction will be:
    # After this pre-cache section, we need to know the exact addresses
    # of the AF operand bytes. Let's build the pre-cache section first,
    # then calculate.
    #
    # Pre-cache reads: LDA $80xx for each operand byte address.
    # We need to read from the exact addresses where the AF operands will be.
    #
    # Current offset: 5 bytes (A9 42 8D 00 04)
    # Pre-cache: 3 LDA abs (3 bytes each) = 9 bytes. Total so far: 14
    # Green border: 5 bytes. Total: 19
    # AF instruction at offset 19: $8009 + 19 = $801C
    # Operand bytes: $801D (AAL), $801E (AAH), $801F (AB)

    # Pre-read the operand byte addresses to fill cache
    # These addresses are the EXACT locations of the AF operands
    af_addr = base + 5 + 9 + 5  # = 0x8009 + 19 = 0x801C
    op1 = af_addr + 1  # $801D - AAL
    op2 = af_addr + 2  # $801E - AAH
    op3 = af_addr + 3  # $801F - AB

    code += bytes([0xAD, op1 & 0xFF, (op1 >> 8) & 0xFF])  # LDA $801D
    code += bytes([0xAD, op2 & 0xFF, (op2 >> 8) & 0xFF])  # LDA $801E
    code += bytes([0xAD, op3 & 0xFF, (op3 >> 8) & 0xFF])  # LDA $801F

    # Verify offset: current code length should be 14
    assert len(code) == 14, f"Expected 14, got {len(code)}"

    # Green border
    code += bytes([0xA9, 0x05])       # LDA #$05
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020

    # Verify: AF should be at offset 19 = addr $801C
    assert len(code) == 19, f"Expected 19, got {len(code)}"

    # THE CRITICAL TEST: LDA long (operands at $801D, $801E, $801F)
    code += bytes([0xAF, 0x00, 0x04, 0x00])  # LDA $000400

    # If we get here, LDA long completed!
    code += bytes([0xC9, 0x42])       # CMP #$42
    code += bytes([0xD0, 0x07])       # BNE wrong

    # PASS: red border
    code += bytes([0xA9, 0x02])       # LDA #$02
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    code += bytes([0x4C])
    here = len(code) - 1
    code += bytes([(base + here - 2) & 0xFF, ((base + here - 2) >> 8) & 0xFF])

    # WRONG: yellow border
    code += bytes([0xA9, 0x07])       # LDA #$07
    code += bytes([0x8D, 0x20, 0xD0]) # STA $D020
    code += bytes([0x4C])
    here2 = len(code) - 1
    code += bytes([(base + here2 - 2) & 0xFF, ((base + here2 - 2) >> 8) & 0xFF])

    return code


if __name__ == '__main__':
    crt_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'crt')
    os.makedirs(crt_dir, exist_ok=True)

    tests = [
        ('1mhz_lda_long', 'Test 1MHz LDA Long', gen_test1_1mhz),
        ('ram_exec_lda_long', 'Test RAM exec LDA Long', gen_test2_ram_exec),
        ('precached_lda_long', 'Test pre-cached LDA Long', gen_test3_precached),
    ]

    for fname, title, gen_func in tests:
        code = gen_func()
        crt_data = make_crt(title, code)
        crt_path = os.path.join(crt_dir, f'{fname}.crt')
        mgl_path = os.path.join(crt_dir, f'{fname}.mgl')

        with open(crt_path, 'wb') as f:
            f.write(crt_data)
        with open(mgl_path, 'w') as f:
            f.write(make_mgl(f'{fname}.crt'))

        print(f"Generated {crt_path} ({len(code)} bytes of code)")
        # Print disassembly
        print(f"  Code starts at $8009:")
        i = 0
        while i < len(code):
            addr = 0x8009 + i
            op = code[i]
            if op == 0xA9:
                print(f"    ${addr:04X}: LDA #${code[i+1]:02X}")
                i += 2
            elif op == 0x8D:
                a = code[i+1] | (code[i+2] << 8)
                print(f"    ${addr:04X}: STA ${a:04X}")
                i += 3
            elif op == 0xAD:
                a = code[i+1] | (code[i+2] << 8)
                print(f"    ${addr:04X}: LDA ${a:04X}")
                i += 3
            elif op == 0xAF:
                a = code[i+1] | (code[i+2] << 8) | (code[i+3] << 16)
                print(f"    ${addr:04X}: LDA ${a:06X}  [ABSOLUTE LONG]")
                i += 4
            elif op == 0xC9:
                print(f"    ${addr:04X}: CMP #${code[i+1]:02X}")
                i += 2
            elif op == 0xD0:
                target = addr + 2 + (code[i+1] if code[i+1] < 128 else code[i+1] - 256)
                print(f"    ${addr:04X}: BNE ${target:04X}")
                i += 2
            elif op == 0x4C:
                a = code[i+1] | (code[i+2] << 8)
                print(f"    ${addr:04X}: JMP ${a:04X}")
                i += 3
            elif op == 0xEA:
                # Count consecutive NOPs
                nop_count = 0
                while i + nop_count < len(code) and code[i + nop_count] == 0xEA:
                    nop_count += 1
                print(f"    ${addr:04X}: NOP x{nop_count}")
                i += nop_count
            else:
                print(f"    ${addr:04X}: ${op:02X}")
                i += 1
        print()
