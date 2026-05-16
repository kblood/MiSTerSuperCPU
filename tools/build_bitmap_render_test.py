#!/usr/bin/env python3
"""Pure 6510 bitmap-mode reference test.

Sets up MCM bitmap mode the same way Doom does (D011=$3B, D016=$D8,
D018=$80, DD00=$02), then fills bank-1 bitmap region $4000-$5FFF with
$AA (all "10" pixel pairs), screen RAM $6000-$63FF with $1F (upper=$1
white, lower=$F light grey), and color RAM $D800-$DBFF with $07.

Expected result:
  Whole bitmap area = light grey (from screen RAM lower nibble of $1F)
  Border = light blue ($D020=$0E)
  Background "00" pixels would be blue ($D021=$06), but bitmap $AA has
  no "00" pairs, so they don't appear.

Failure modes:
  All black            -> VIC bitmap fetch path broken on this branch
  Garbled colors       -> color path partial
  Light grey rendered  -> VIC bitmap path works -> Doom-specific bug
                          (SCPU long-store mirror, JIT, or render code)

No SCPU instructions used. Runs in pure 6510 / emulation mode where the
Tier-3 bank-$01 mirror is OFF. Tests VIC-side memory routing only.
"""
import os, struct


def main():
    code = bytearray()
    # BASIC stub: 10 SYS 2061
    code += bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36,
                   0x31, 0x00, 0x00, 0x00])

    def addr_of(o): return 0x0801 + o
    assert addr_of(len(code)) == 0x080D

    def emit(*bs): code.extend(bs)

    emit(0x78)                            # SEI
    emit(0xD8)                            # CLD

    emit(0xA9, 0x3B); emit(0x8D, 0x11, 0xD0)  # D011: BMM + DEN + 25rows + ysc=3
    emit(0xA9, 0xD8); emit(0x8D, 0x16, 0xD0)  # D016: MCM + 40cols
    emit(0xA9, 0x80); emit(0x8D, 0x18, 0xD0)  # D018: screen=$2000 char=$0000
    emit(0xA9, 0x02); emit(0x8D, 0x00, 0xDD)  # DD00: VIC bank 1 ($4000-$7FFF)
    emit(0xA9, 0x02); emit(0x8D, 0x20, 0xD0)  # D020: RED border (signature)
    emit(0xA9, 0x05); emit(0x8D, 0x21, 0xD0)  # D021: GREEN bg ("00" color)

    # ptr $FB/$FC = $4000
    emit(0xA9, 0x00); emit(0x85, 0xFB)
    emit(0xA9, 0x40); emit(0x85, 0xFC)

    # outer loop: fill bitmap $4000-$5FFF with $AA
    fill_bm = addr_of(len(code))
    emit(0xA9, 0xAA)
    emit(0xA0, 0x00)
    inner = addr_of(len(code))
    emit(0x91, 0xFB)                      # STA ($FB),Y
    emit(0xC8)                            # INY
    bpc = addr_of(len(code) + 2); emit(0xD0, (inner - bpc) & 0xFF)
    emit(0xE6, 0xFC)                      # INC $FC
    emit(0xA5, 0xFC); emit(0xC9, 0x60)    # CMP #$60 (stop at $6000)
    bpc = addr_of(len(code) + 2); emit(0xD0, (fill_bm - bpc) & 0xFF)

    # ptr $FB/$FC = $6000, fill $6000-$63FF with $1F
    emit(0xA9, 0x00); emit(0x85, 0xFB)
    emit(0xA9, 0x60); emit(0x85, 0xFC)

    fill_scr = addr_of(len(code))
    emit(0xA9, 0x1F)
    emit(0xA0, 0x00)
    inner = addr_of(len(code))
    emit(0x91, 0xFB)
    emit(0xC8)
    bpc = addr_of(len(code) + 2); emit(0xD0, (inner - bpc) & 0xFF)
    emit(0xE6, 0xFC)
    emit(0xA5, 0xFC); emit(0xC9, 0x64)
    bpc = addr_of(len(code) + 2); emit(0xD0, (fill_scr - bpc) & 0xFF)

    # Fill color RAM $D800-$DBFF with $07 (yellow "11" pixels — n/a for $AA)
    emit(0xA9, 0x07)
    emit(0xA2, 0x00)
    fill_col = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)
    emit(0x9D, 0x00, 0xD9)
    emit(0x9D, 0x00, 0xDA)
    emit(0x9D, 0x00, 0xDB)
    emit(0xE8)
    bpc = addr_of(len(code) + 2); emit(0xD0, (fill_col - bpc) & 0xFF)

    hang = addr_of(len(code))
    emit(0x4C, hang & 0xFF, (hang >> 8) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'bitmap_render_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print('Wrote %s: %d bytes' % (out, len(prg)))


if __name__ == '__main__':
    main()
