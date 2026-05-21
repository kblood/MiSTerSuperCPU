#!/usr/bin/env python3
"""Peek-bitmap diagnostic. Samples 16 bytes at 256-byte stride from
$4000-$5FFF (Doom page A) and 16 from $C000-$DFFF (Doom page B). Paints
them as 32 hex digits each on screen rows 0 and 1.

Border color:
  $00 = both regions all-zero
  $01 = only $4000-$5FFF has data
  $02 = only $C000-$DFFF has data
  $03 = both have data

If border is $00, Doom never wrote bitmap to either page. Bug is in
Doom-init path, not render path.
If non-zero, the hex dump reveals what Doom wrote.
"""
import os, struct


def main():
    code = bytearray()
    code += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36,
                   0x31, 0x00, 0x00, 0x00])

    def addr_of(o): return 0x0801 + o
    assert addr_of(len(code)) == 0x080D

    def emit(*bs): code.extend(bs)

    # nibble-to-screen-code LUT will be placed at end of code.
    # Resolve its address later via a fixup.
    lut_addr_placeholder_locs = []

    def emit_LDA_LUT_X():
        # LDA lut,X => $BD lo hi (3 bytes). Record the (offset-of-low-byte, type)
        # for later fixup.
        emit(0xBD, 0x00, 0x00)
        lut_addr_placeholder_locs.append(len(code) - 2)

    def paint_byte(src_zp, screen_addr):
        # HIGH nibble
        emit(0xA5, src_zp)                       # LDA src
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
        emit(0xAA)                               # TAX
        emit_LDA_LUT_X()
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)
        # LOW nibble
        emit(0xA5, src_zp)
        emit(0x29, 0x0F)
        emit(0xAA)
        emit_LDA_LUT_X()
        emit(0x8D, (screen_addr + 1) & 0xFF, ((screen_addr + 1) >> 8) & 0xFF)

    emit(0x78)        # SEI
    emit(0xD8)        # CLD

    # Sample 16 bytes from $4000-$5FFF at 256-byte stride into $80-$8F
    for i in range(16):
        src = 0x4000 + (i * 0x100)
        emit(0xAD, src & 0xFF, (src >> 8) & 0xFF)
        emit(0x85, 0x80 + i)

    # Sample 16 bytes from $C000-$DFFF at 256-byte stride into $A0-$AF
    for i in range(16):
        src = 0xC000 + (i * 0x100)
        emit(0xAD, src & 0xFF, (src >> 8) & 0xFF)
        emit(0x85, 0xA0 + i)

    # OR all $80-$8F into $90
    emit(0xA9, 0x00); emit(0x85, 0x90)
    for i in range(16):
        emit(0xA5, 0x80 + i); emit(0x05, 0x90); emit(0x85, 0x90)

    # OR all $A0-$AF into $91
    emit(0xA9, 0x00); emit(0x85, 0x91)
    for i in range(16):
        emit(0xA5, 0xA0 + i); emit(0x05, 0x91); emit(0x85, 0x91)

    # Border color
    emit(0xA9, 0x00); emit(0x85, 0x92)
    emit(0xA5, 0x90); emit(0xF0, 0x06)
    emit(0xA9, 0x01); emit(0x05, 0x92); emit(0x85, 0x92)
    emit(0xA5, 0x91); emit(0xF0, 0x06)
    emit(0xA9, 0x02); emit(0x05, 0x92); emit(0x85, 0x92)
    emit(0xA5, 0x92); emit(0x8D, 0x20, 0xD0)

    # Paint row 0 from $80-$8F
    for i in range(16):
        paint_byte(0x80 + i, 0x0400 + i * 2)

    # Paint row 1 from $A0-$AF
    for i in range(16):
        paint_byte(0xA0 + i, 0x0428 + i * 2)

    # Hang
    hang = addr_of(len(code))
    emit(0x4C, hang & 0xFF, (hang >> 8) & 0xFF)

    # Emit LUT
    lut_offset_in_code = len(code)
    lut_addr = addr_of(lut_offset_in_code)
    # Screen codes: '0'..'9' = $30..$39; 'A'..'F' = $01..$06
    code.extend([0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
                 0x38, 0x39, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

    # Fixup LDA lut,X operands
    for offs in lut_addr_placeholder_locs:
        code[offs]     = lut_addr & 0xFF
        code[offs + 1] = (lut_addr >> 8) & 0xFF

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'peek_bitmap.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print('Wrote %s: %d bytes; LUT at $%04X' % (out, len(prg), lut_addr))


if __name__ == '__main__':
    main()
