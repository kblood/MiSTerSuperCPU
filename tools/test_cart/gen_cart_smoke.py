#!/usr/bin/env python3
"""Minimal raw-cart smoke test: runs DIRECTLY from cart space at $8009.

If CBM80 auto-boot works at all, border turns WHITE within 1 frame.
No payload-copy, no BASIC stub. Validates the CRT loader path before
we trust prg_to_crt.py.
"""
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out',
                   'cart_smoke.crt')

def main():
    rom = bytearray(8192)
    code_start = 0x8009
    rom[0] = code_start & 0xFF
    rom[1] = (code_start >> 8) & 0xFF
    rti_addr = 0x8030
    rom[2] = rti_addr & 0xFF
    rom[3] = (rti_addr >> 8) & 0xFF
    rom[4:9] = bytes([0xC3, 0xC2, 0xCD, 0x38, 0x30])

    code = []
    code += [0x78]                            # SEI
    code += [0xD8]                            # CLD
    code += [0xA2, 0xFF, 0x9A]                # LDX #$FF; TXS
    code += [0xA9, 0x0F]                      # LDA #$0F (white)
    code += [0x8D, 0x20, 0xD0]                # STA $D020
    code += [0xA9, 0x06]                      # LDA #$06 (blue)
    code += [0x8D, 0x21, 0xD0]                # STA $D021
    # Halt
    target = code_start + len(code)
    code += [0x4C, target & 0xFF, (target >> 8) & 0xFF]   # JMP self

    for i, b in enumerate(code):
        rom[9 + i] = b
    rom[0x27] = 0x40  # NMI RTI fallback (not used)

    header = bytearray(64)
    header[0:16] = b'C64 CARTRIDGE   '
    struct.pack_into('>I', header, 16, 64)
    struct.pack_into('>H', header, 20, 0x0100)
    struct.pack_into('>H', header, 22, 0)
    header[24] = 0
    header[25] = 1
    header[32:32+10] = b'CART SMOKE'

    chip = bytearray(16)
    chip[0:4] = b'CHIP'
    struct.pack_into('>I', chip, 4, 16 + 8192)
    struct.pack_into('>H', chip, 12, 0x8000)
    struct.pack_into('>H', chip, 14, 0x2000)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(bytes(header) + bytes(chip) + bytes(rom))
    print(f"Wrote {OUT}: {len(header)+len(chip)+len(rom)} bytes, code={len(code)} bytes")

if __name__ == '__main__':
    main()
