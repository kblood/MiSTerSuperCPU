#!/usr/bin/env python3
"""SCPU-native bitmap test — fills bank-1 bitmap region via long-stores.

Sets up MCM bitmap mode (same as Doom), enters 65C816 native mode via
CLC; XCE, then uses STA long $01:$4000,X (opcode 9F) to fill the bank-1
bitmap area. This exercises the Tier-3 bank-$01-mirror path that Doom's
JIT recompiler uses for runtime bitmap writes.

Expected: red border + light grey bitmap area (just like the pure-6510
test bitmap_render_test.prg).
Failure mode: black bitmap area -> Tier-3 mirror routing is broken for
bank-$01 long-stores in native mode.
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
    emit(0xC2, 0x10)                            # REP #$10  X=0 (16-bit X)
    emit(0xE2, 0x20)                            # SEP #$20  M=1 (8-bit A)

    emit(0xA9, 0x3B); emit(0x8D, 0x11, 0xD0)    # D011: BMM+DEN+25rows
    emit(0xA9, 0xD8); emit(0x8D, 0x16, 0xD0)    # D016: MCM
    emit(0xA9, 0x80); emit(0x8D, 0x18, 0xD0)    # D018: screen=$2000 char=$0000
    emit(0xA9, 0x02); emit(0x8D, 0x00, 0xDD)    # DD00: bank 1
    emit(0xA9, 0x02); emit(0x8D, 0x20, 0xD0)    # D020: RED
    emit(0xA9, 0x05); emit(0x8D, 0x21, 0xD0)    # D021: GREEN

    # Fill $01:$4000-$01:$5FFF with $AA via long-X store
    emit(0xA2, 0x00, 0x00)                      # LDX #$0000 (16-bit)
    emit(0xA9, 0xAA)                            # LDA #$AA
    fillbm = addr_of(len(code))
    emit(0x9F, 0x00, 0x40, 0x01)                # STA $014000,X
    emit(0xE8)                                  # INX (16-bit)
    emit(0xE0, 0x00, 0x20)                      # CPX #$2000
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillbm - bpc) & 0xFF)

    # Fill $01:$6000-$01:$63FF (screen RAM) with $1F via long-X store
    emit(0xA2, 0x00, 0x00)
    emit(0xA9, 0x1F)
    fillscr = addr_of(len(code))
    emit(0x9F, 0x00, 0x60, 0x01)                # STA $016000,X
    emit(0xE8)
    emit(0xE0, 0x00, 0x04)                      # CPX #$0400
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillscr - bpc) & 0xFF)

    # Color RAM $D800-$DBFF with $07 (regular 16-bit-X absolute)
    emit(0xA2, 0x00, 0x00)
    emit(0xA9, 0x07)
    fillcol = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)                      # STA $D800,X
    emit(0xE8)
    emit(0xE0, 0x00, 0x04)
    bpc = addr_of(len(code) + 2); emit(0xD0, (fillcol - bpc) & 0xFF)

    hang = addr_of(len(code))
    emit(0x4C, hang & 0xFF, (hang >> 8) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'bitmap_render_test_scpu.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print('Wrote %s: %d bytes' % (out, len(prg)))


if __name__ == '__main__':
    main()
