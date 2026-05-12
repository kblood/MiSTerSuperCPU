#!/usr/bin/env python3
"""Build reu_peek_doom_hex.prg — read 6 known doom.reu bytes via REU FETCH,
paint each byte as 2 hex digits on screen row 0 so it's directly readable.

Layout on row 0 ($0400..$0427):
  cols 0..1 : byte from REU $200000  (expected 78)
  cols 3..4 :              $200001  (expected D8)
  cols 6..7 :              $400000  (expected FF)
  cols 9..10:              $400001  (expected 8C)
  cols 12..13:             $800000  (expected 53)
  cols 15..16:             $800001  (expected 43)

Border = colour-RAM bg painted from first byte's lower nibble (so $78 → orange).
"""
import os, struct, sys

PROBES = [
    (0x200000, 0xF0,  0),  # col on row 0
    (0x200001, 0xF1,  3),
    (0x400000, 0xF2,  6),
    (0x400001, 0xF3,  9),
    (0x800000, 0xF4, 12),
    (0x800001, 0xF5, 15),
]

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08,0x00,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
    code += stub
    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    # Native mode, M=8, X=16
    emit(0x78, 0x18, 0xFB)            # SEI; CLC; XCE
    emit(0xEA, 0xEA, 0xEA, 0xEA)      # absorb XCE drop+scramble
    emit(0xC2, 0x10)                  # X=16
    emit(0xE2, 0x20)                  # M=8

    # Blank screen RAM rows 0-2 (40*3 = 120 bytes) with screen-code $20 (space)
    emit(0xA9, 0x20)                  # LDA #$20
    emit(0xA2, 0x00, 0x00)            # LDX #0
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0x04)            # STA $0400,X
    emit(0xE8)
    emit(0xE0, 0x78, 0x00)            # CPX #120
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (lp - bpc) & 0xFF)

    # Set colour RAM row 0 (40 bytes) to white ($01) so chars are readable
    emit(0xA9, 0x01)
    emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)            # STA $D800,X
    emit(0xE8)
    emit(0xE0, 0x28, 0x00)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (lp - bpc) & 0xFF)

    # ---- 6 REU FETCHes into $F0..$F5 ----
    for reu_off, dest_zp, _col in PROBES:
        reu_lo  =  reu_off        & 0xFF
        reu_mid = (reu_off >> 8)  & 0xFF
        reu_hi  = (reu_off >> 16) & 0xFF
        emit(0xA9, dest_zp); emit(0x8D, 0x02, 0xDF)
        emit(0xA9, 0x00);    emit(0x8D, 0x03, 0xDF)
        emit(0xA9, reu_lo);  emit(0x8D, 0x04, 0xDF)
        emit(0xA9, reu_mid); emit(0x8D, 0x05, 0xDF)
        emit(0xA9, reu_hi);  emit(0x8D, 0x06, 0xDF)
        emit(0xA9, 0x01);    emit(0x8D, 0x07, 0xDF)
        emit(0xA9, 0x00);    emit(0x8D, 0x08, 0xDF)
        emit(0xA9, 0x91);    emit(0x8D, 0x01, 0xDF)   # FETCH

    # ---- For each probe, paint 2 hex digits on row 0 ----
    def paint_hex(zp, col):
        screen_addr = 0x0400 + col
        # high nibble
        emit(0xA5, zp)                    # LDA zp
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A) # LSR x4
        # CMP/BCC/SEC/SBC/BRA/CLC/ADC sequence, branch offsets verified
        emit(0xC9, 0x0A)                  # CMP #$0A       (bytes 0-1)
        emit(0x90, 0x05)                  # BCC +5 to CLC  (bytes 2-3)
        emit(0x38)                        # SEC            (byte 4)
        emit(0xE9, 0x09)                  # SBC #$09       (bytes 5-6)
        emit(0x80, 0x03)                  # BRA +3 to STA  (bytes 7-8)
        emit(0x18)                        # CLC            (byte 9, BCC target)
        emit(0x69, 0x30)                  # ADC #$30       (bytes 10-11)
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)  # STA abs (byte 12, BRA target)
        # low nibble
        emit(0xA5, zp)
        emit(0x29, 0x0F)                  # AND #$0F
        emit(0xC9, 0x0A)
        emit(0x90, 0x05)
        emit(0x38)
        emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18)
        emit(0x69, 0x30)
        screen_addr2 = screen_addr + 1
        emit(0x8D, screen_addr2 & 0xFF, (screen_addr2 >> 8) & 0xFF)

    for reu_off, dest_zp, col in PROBES:
        paint_hex(dest_zp, col)

    # Set border = $F0 lower-nibble (visual confirmation of first byte)
    emit(0xA5, 0xF0)
    emit(0x29, 0x0F)
    emit(0x8D, 0x20, 0xD0)

    # Spin forever
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'reu_peek_doom_hex.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print('Expected screen row 0 (read left-to-right):')
    print('  cols 0-1 : "78"   (REU $200000)')
    print('  cols 3-4 : "D8"   (REU $200001)')
    print('  cols 6-7 : "FF"   (REU $400000)')
    print('  cols 9-10: "8C"   (REU $400001)')
    print('  cols 12-13: "53"  (REU $800000)')
    print('  cols 15-16: "43"  (REU $800001)')
    print('  Border = $08 (lower nibble of $78 = orange)')
    print()
    print('Divergence from expected = REU read corruption.')

if __name__ == '__main__':
    sys.exit(main() or 0)
