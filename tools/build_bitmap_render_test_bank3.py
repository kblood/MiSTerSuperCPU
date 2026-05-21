#!/usr/bin/env python3
"""SCPU-native bitmap test using VIC bank 3 ($C000-$FFFF).

Same approach as the SCPU bank-1 test but uses DD00=$00 (bank 3),
filling bank-1 long-store $01:$C000-$01:$DFFF for bitmap (which the
Tier-3 mirror should route to bank-0 SDRAM $C000-$DFFF where VIC
bank-3 reads bitmap), and $01:$E000-$01:$E3FF for screen RAM.

This is the OTHER page of Doom's double-buffer that page-flip alternates.

Expected: red border + light grey bitmap area.
Failure (black): Tier-3 mirror routes bank-$01 with c64_addr in
$C000-$DFFF range to a different SDRAM location than where VIC reads.
"""
import os, struct


def main():
    code = bytearray()
    code += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36,
                   0x31, 0x00, 0x00, 0x00])

    def addr_of(o): return 0x0801 + o
    assert addr_of(len(code)) == 0x080D

    def emit(*bs): code.extend(bs)

    emit(0x78)                                  # SEI
    emit(0x18)                                  # CLC
    emit(0xFB)                                  # XCE -> native
    emit(0xC2, 0x10)                            # REP #$10  X=0
    emit(0xE2, 0x20)                            # SEP #$20  M=1

    emit(0xA9, 0x3B); emit(0x8D, 0x11, 0xD0)    # D011: BMM+DEN
    emit(0xA9, 0xD8); emit(0x8D, 0x16, 0xD0)    # D016: MCM
    emit(0xA9, 0x80); emit(0x8D, 0x18, 0xD0)    # D018: VM=$2000 CB=$0000 (in bank)
    emit(0xA9, 0x00); emit(0x8D, 0x00, 0xDD)    # DD00: bank 3 ($C000-$FFFF)
    emit(0xA9, 0x02); emit(0x8D, 0x20, 0xD0)    # D020: RED
    emit(0xA9, 0x05); emit(0x8D, 0x21, 0xD0)    # D021: GREEN

    # Fill $01:$C000-$01:$DFFF with $AA (bank-1 mirror -> bank-0 $C000-$DFFF
    # = bitmap region for VIC bank 3)
    emit(0xA2, 0x00, 0x00)
    emit(0xA9, 0xAA)
    fillbm = addr_of(len(code))
    emit(0x9F, 0x00, 0xC0, 0x01)                # STA $01C000,X
    emit(0xE8)
    emit(0xE0, 0x00, 0x20)                      # CPX #$2000
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillbm - bpc) & 0xFF)

    # Fill $01:$E000-$01:$E3FF with $1F (screen RAM at $E000 in bank 3)
    emit(0xA2, 0x00, 0x00)
    emit(0xA9, 0x1F)
    fillscr = addr_of(len(code))
    emit(0x9F, 0x00, 0xE0, 0x01)                # STA $01E000,X
    emit(0xE8)
    emit(0xE0, 0x00, 0x04)                      # CPX #$0400
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillscr - bpc) & 0xFF)

    # Color RAM $D800-$DBFF with $07
    emit(0xA2, 0x00, 0x00)
    emit(0xA9, 0x07)
    fillcol = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)
    emit(0xE8)
    emit(0xE0, 0x00, 0x04)
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillcol - bpc) & 0xFF)

    hang = addr_of(len(code))
    emit(0x4C, hang & 0xFF, (hang >> 8) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'bitmap_render_test_bank3.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print('Wrote %s: %d bytes' % (out, len(prg)))


if __name__ == '__main__':
    main()
