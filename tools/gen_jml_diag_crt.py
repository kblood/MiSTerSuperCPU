#!/usr/bin/env python3
"""Generate diagnostic CRTs to isolate the LDA long ($AF) hang.

Test A: JML long jump (4-byte instruction using AB register)
  - If JML works → 4-byte fetch + AB loading is OK, bug is in $AF data read
  - If JML hangs → 4-byte fetch mechanism itself is broken

Test B: STA long ($8F) followed by LDA absolute ($AD) to verify the write
  - If STA long works → write path through AB:AA is OK
  - Helps isolate read vs write path

Test C: LDA long from different bank ($AF with AB=$00 but using DBR setup)
  - Another variant of the LDA long test

Test D: JSL (JSR long, $22) to a subroutine and RTL back
  - Tests another 4-byte instruction with different microcode

Each test shows GREEN border before the critical instruction.
RED border = test PASSED. YELLOW = test FAILED.
Border stays GREEN if CPU hangs at the critical instruction.
"""
import struct
import sys
import os

def make_crt_header(name_bytes):
    """Build a standard 64-byte CRT header for 8K cart."""
    hdr = bytearray(64)
    hdr[0:16] = b'C64 CARTRIDGE   '
    struct.pack_into('>I', hdr, 16, 64)  # header length
    struct.pack_into('>H', hdr, 20, 0x0100)  # version
    struct.pack_into('>H', hdr, 22, 0)  # type = normal
    hdr[24] = 0  # EXROM = 0 (active low, directly active)
    hdr[25] = 1  # GAME = 1
    hdr[32:32+len(name_bytes)] = name_bytes
    return hdr

def make_chip_packet(load_addr, data):
    """Build a CHIP packet."""
    total = 16 + len(data)
    pkt = bytearray(16)
    pkt[0:4] = b'CHIP'
    struct.pack_into('>I', pkt, 4, total)
    struct.pack_into('>H', pkt, 8, 0)  # ROM
    struct.pack_into('>H', pkt, 10, 0)  # bank 0
    struct.pack_into('>H', pkt, 12, load_addr)
    struct.pack_into('>H', pkt, 14, len(data))
    return bytes(pkt) + bytes(data)

def make_rom(code, entry_offset=9):
    """Build an 8KB ROM with CBM80 header at $8000."""
    rom = bytearray(8192)
    entry = 0x8000 + entry_offset
    rom[0] = entry & 0xFF        # reset vector low
    rom[1] = (entry >> 8) & 0xFF # reset vector high
    rom[2] = entry & 0xFF        # NMI vector low (same)
    rom[3] = (entry >> 8) & 0xFF
    rom[4:9] = bytes([0xC3, 0xC2, 0xCD, 0x38, 0x30])  # CBM80 magic
    rom[entry_offset:entry_offset+len(code)] = code
    return rom

def make_mgl(crt_filename):
    """Generate MGL content."""
    return f'''<mistergamedescription>
  <rbf>_Test/C64</rbf>
  <file delay="3" type="f" index="1" path="{crt_filename}"/>
</mistergamedescription>
'''

def gen_test_a():
    """Test A: JML (Jump Long) test.
    JML $5C is a 4-byte instruction: $5C lo hi bank
    Tests: 4-byte fetch, AB register loading, long jump.
    GREEN = pre-JML, RED = JML succeeded, YELLOW = JML failed (fell through)
    """
    code = bytearray()
    # $8009: LDA #$05 (green border = about to JML)
    code += bytes([0xA9, 0x05])
    # $800B: STA $D020
    code += bytes([0x8D, 0x20, 0xD0])
    # $800E: JML $008019 (jump to the red-border code below)
    # JML target is at offset 0x19 from $8000 = $8019
    target = 0x8019
    code += bytes([0x5C, target & 0xFF, (target >> 8) & 0xFF, 0x00])
    # $8012: (fall-through = JML failed)
    # LDA #$07 (yellow border = JML skipped)
    code += bytes([0xA9, 0x07])
    # $8014: STA $D020
    code += bytes([0x8D, 0x20, 0xD0])
    # $8017: JMP $8017 (infinite loop — failure)
    code += bytes([0x4C, 0x17, 0x80])
    # $801A: -- wait, let me recalculate
    # Actually at $8009 + len so far...
    # Let me be more precise:
    # $8009: A9 05       (2 bytes)
    # $800B: 8D 20 D0    (3 bytes)
    # $800E: 5C xx xx xx (4 bytes)
    # $8012: A9 07       (2 bytes)
    # $8014: 8D 20 D0    (3 bytes)
    # $8017: 4C 17 80    (3 bytes)
    # $801A: -- JML target should be here
    # Oops, I said target = $8019 but it should be $801A
    # Let me fix: target should be at offset from code start
    # Code is at offset 9 in ROM. Addresses are $8000 + offset.
    # Target = $8009 + 17 = $801A? Let me count bytes:
    # A9 05 = 2 → total 2
    # 8D 20 D0 = 3 → total 5
    # 5C xx xx xx = 4 → total 9
    # A9 07 = 2 → total 11
    # 8D 20 D0 = 3 → total 14
    # 4C 17 80 = 3 → total 17
    # So the code after the failure loop starts at $8009 + 17 = $801A
    pass

    # Let me redo this more carefully
    code = bytearray()
    base = 0x8009  # entry point

    # Green border marker
    code += bytes([0xA9, 0x05])     # LDA #$05
    code += bytes([0x8D, 0x20, 0xD0])  # STA $D020

    # JML target calculation: code so far = 5 bytes from $8009 = $800E
    # JML is 4 bytes, fail code is 2+3+3 = 8 bytes
    # Fail code ends at $800E + 4 + 8 = $801A
    # JML target = $801A (the success code)
    jml_target = base + 5 + 4 + 8  # $801A

    code += bytes([0x5C, jml_target & 0xFF, (jml_target >> 8) & 0xFF, 0x00])

    # Fall-through (JML failed) — yellow border
    code += bytes([0xA9, 0x07])     # LDA #$07
    code += bytes([0x8D, 0x20, 0xD0])  # STA $D020
    fail_addr = base + len(code)
    code += bytes([0x4C, fail_addr & 0xFF, (fail_addr >> 8) & 0xFF])

    # JML target — red border (success!)
    assert base + len(code) == jml_target, f"JML target mismatch: {base + len(code):#06x} vs {jml_target:#06x}"
    code += bytes([0xA9, 0x02])     # LDA #$02
    code += bytes([0x8D, 0x20, 0xD0])  # STA $D020
    pass_addr = base + len(code)
    code += bytes([0x4C, pass_addr & 0xFF, (pass_addr >> 8) & 0xFF])

    return code

def gen_test_b():
    """Test B: STA long ($8F) + LDA absolute ($AD) verify.
    Tests: write through AB:AA path.
    GREEN = pre-STA, RED = STA+verify succeeded, YELLOW = verify failed.
    """
    code = bytearray()
    base = 0x8009

    # Store a known value using STA long
    code += bytes([0xA9, 0x55])     # LDA #$55
    # Green border
    code += bytes([0xA9, 0x05])     # LDA #$05 (we'll restore A after)
    code += bytes([0x8D, 0x20, 0xD0])  # STA $D020
    code += bytes([0xA9, 0x55])     # LDA #$55 (reload)

    # STA $000402 (absolute long store)
    code += bytes([0x8F, 0x02, 0x04, 0x00])

    # Now verify with LDA absolute (which works)
    code += bytes([0xAD, 0x02, 0x04])  # LDA $0402

    # CMP #$55
    code += bytes([0xC9, 0x55])

    # BNE fail
    fail_rel = 5  # skip over success code to fail code
    code += bytes([0xD0, fail_rel])

    # Success: red border
    code += bytes([0xA9, 0x02])
    code += bytes([0x8D, 0x20, 0xD0])
    pass_addr = base + len(code)
    code += bytes([0x4C, pass_addr & 0xFF, (pass_addr >> 8) & 0xFF])

    # Fail: yellow border
    code += bytes([0xA9, 0x07])
    code += bytes([0x8D, 0x20, 0xD0])
    fail_addr = base + len(code)
    code += bytes([0x4C, fail_addr & 0xFF, (fail_addr >> 8) & 0xFF])

    return code

def gen_test_c():
    """Test C: JSL ($22) + RTL ($6B) test.
    JSL is a 4-byte instruction. Tests 4-byte fetch + subroutine call/return.
    GREEN = pre-JSL, RED = JSL+RTL succeeded, YELLOW = fell through JSL.
    """
    code = bytearray()
    base = 0x8009

    # Green border
    code += bytes([0xA9, 0x05])
    code += bytes([0x8D, 0x20, 0xD0])

    # JSL target: will be the subroutine at end
    # JSL is at $8009 + 5 = $800E
    # JSL is 4 bytes → after JSL, PC = $8012
    # Fall-through code for "JSL failed": 2+3+3 = 8 bytes → ends at $801A
    # Subroutine target: $801A
    jsl_pos = base + 5
    after_jsl = jsl_pos + 4  # $8012
    # After JSL returns, execution continues at $8012

    # Success code after RTL returns: red border
    # This goes at $8012
    # But wait: if JSL fails and falls through, we'd hit this code too
    # Let me restructure:

    code = bytearray()
    base = 0x8009

    # Green border
    code += bytes([0xA9, 0x05])           # $8009
    code += bytes([0x8D, 0x20, 0xD0])     # $800B

    # JSL to subroutine
    # Subroutine will set A=#$AA and RTL
    # After RTL, check A=#$AA
    sub_addr = base + 5 + 4 + 2 + 3 + 5 + 8  # calculate later
    code += bytes([0x22, 0x00, 0x00, 0x00])  # placeholder JSL
    jsl_offset = len(code) - 4 + 1  # offset of the low byte in code array
    # Note: JSL pushes PBR and PC+3 on stack, then jumps to target

    # After RTL: check A = $AA
    code += bytes([0xC9, 0xAA])           # CMP #$AA

    # BNE fail
    code += bytes([0xD0, 0x05])           # BNE +5

    # Success: red border
    code += bytes([0xA9, 0x02])
    code += bytes([0x8D, 0x20, 0xD0])
    pass_addr = base + len(code)
    code += bytes([0x4C, pass_addr & 0xFF, (pass_addr >> 8) & 0xFF])

    # Fail: yellow border
    code += bytes([0xA9, 0x07])
    code += bytes([0x8D, 0x20, 0xD0])
    fail_addr = base + len(code)
    code += bytes([0x4C, fail_addr & 0xFF, (fail_addr >> 8) & 0xFF])

    # Subroutine: load A with $AA and RTL
    sub_addr = base + len(code)
    code += bytes([0xA9, 0xAA])           # LDA #$AA
    code += bytes([0x6B])                 # RTL

    # Patch JSL target
    # JSL operand is at code offset (5) after the 5C opcode
    jsl_code_offset = 5  # LDA + STA = 5 bytes, then JSL starts
    code[jsl_code_offset + 1] = sub_addr & 0xFF
    code[jsl_code_offset + 2] = (sub_addr >> 8) & 0xFF
    code[jsl_code_offset + 3] = 0x00  # bank $00

    return code

def gen_test_d():
    """Test D: PEA ($F4) test — 3-byte instruction, pushes 16-bit value.
    This is a simpler multi-byte instruction that doesn't use AB.
    Tests: 3-operand-byte fetch without AB involvement.
    GREEN = pre-PEA, RED = PEA succeeded, YELLOW = PEA failed.
    
    Actually, PEA is only 3 bytes. Let me use a different 4-byte instruction.
    
    Test D: MVN ($54) — block move, uses 3 operand bytes
    Actually MVN is only 3 bytes (opcode + src_bank + dst_bank).
    
    Let me use: LDA [dp] ($A7) — this is indirect long from direct page.
    In emulation mode, this reads from [dp], a 24-bit pointer in page zero.
    
    Actually, let me just do a minimal AB address test:
    Store $42 to $0400 using STA abs, then read it back with LDA long.
    But use a NOP sled and different timing to see if the hang is timing-dependent.
    """
    # Test D: LDA long with explicit 20MHz enable first ($D07B write)
    code = bytearray()
    base = 0x8009

    # Enable 20MHz turbo explicitly via $D07B
    code += bytes([0x8D, 0x7B, 0xD0])    # STA $D07B (value doesn't matter)

    # NOP sled to settle
    code += bytes([0xEA] * 8)

    # Store known value
    code += bytes([0xA9, 0x42])           # LDA #$42
    code += bytes([0x8D, 0x00, 0x04])     # STA $0400

    # NOP sled
    code += bytes([0xEA] * 8)

    # Green border
    code += bytes([0xA9, 0x05])
    code += bytes([0x8D, 0x20, 0xD0])

    # NOP sled
    code += bytes([0xEA] * 8)

    # LDA long $000400
    code += bytes([0xAF, 0x00, 0x04, 0x00])

    # CMP #$42
    code += bytes([0xC9, 0x42])

    # BNE fail
    code += bytes([0xD0, 0x05])

    # Success: red border
    code += bytes([0xA9, 0x02])
    code += bytes([0x8D, 0x20, 0xD0])
    pass_addr = base + len(code)
    code += bytes([0x4C, pass_addr & 0xFF, (pass_addr >> 8) & 0xFF])

    # Fail: yellow border
    code += bytes([0xA9, 0x07])
    code += bytes([0x8D, 0x20, 0xD0])
    fail_addr = base + len(code)
    code += bytes([0x4C, fail_addr & 0xFF, (fail_addr >> 8) & 0xFF])

    return code

def main():
    tests = {
        'jml_test': ('JML TEST', gen_test_a),
        'sta_long_test': ('STA LONG', gen_test_b),
        'jsl_test': ('JSL TEST', gen_test_c),
        'lda_long_turbo': ('LDA LONG TURBO', gen_test_d),
    }

    outdir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'crt')
    os.makedirs(outdir, exist_ok=True)

    for name, (label, gen_fn) in tests.items():
        code = gen_fn()
        rom = make_rom(code)
        crt = make_crt_header(label.encode('ascii')[:32]) + make_chip_packet(0x8000, rom)
        crt_path = os.path.join(outdir, f'{name}.crt')
        with open(crt_path, 'wb') as f:
            f.write(crt)
        print(f'Generated {crt_path} ({len(code)} bytes of code)')

        # MGL
        mgl_path = os.path.join(outdir, f'{name}.mgl')
        with open(mgl_path, 'w') as f:
            f.write(make_mgl(f'/media/usb0/C64/{name}.crt'))
        print(f'Generated {mgl_path}')

    print('\nTest summary:')
    print('  jml_test:       GREEN=pre-JML, RED=JML works, YELLOW=JML failed')
    print('  sta_long_test:  GREEN=pre-STA, RED=STA+verify works, YELLOW=verify failed')
    print('  jsl_test:       GREEN=pre-JSL, RED=JSL+RTL works, YELLOW=JSL failed')
    print('  lda_long_turbo: GREEN=pre-LDA, RED=LDA long works, YELLOW=data mismatch')
    print('  (border stays GREEN if CPU hangs at the critical instruction)')

if __name__ == '__main__':
    main()
