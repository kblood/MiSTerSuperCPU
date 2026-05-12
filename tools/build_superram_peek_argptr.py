#!/usr/bin/env python3
"""Build superram_peek_argptr.prg — read SuperRAM at suspected music_num
arg-pointer sources to find where -9 lives.

Targets (long-LDA, 1 byte each):
  Row 0: $87:$EAD8 / $87:$EAD9 / $87:$EADA / $87:$EADB
         + $87:$EADC / $87:$EADD
         (the printf walker's long-pointer source; doom.reu = all zeros,
          if SuperRAM differs the runtime has written non-zero values)
  Row 1: $87:$EB0C / $87:$EB0D / $87:$EB0E / $87:$EB0F
         + $86:$EAD0 / $86:$EAD1
         (alternate walker step locations; doom.reu also zeros)

Run AFTER full Doom has wedged (so loader has populated all SuperRAM).
"""
import os, struct, sys

PROBES_ROW0 = [
    (0x87, 0xEAD8, 0xF0,  0),
    (0x87, 0xEAD9, 0xF1,  3),
    (0x87, 0xEADA, 0xF2,  6),
    (0x87, 0xEADB, 0xF3,  9),
    (0x87, 0xEADC, 0xF4, 12),
    (0x87, 0xEADD, 0xF5, 15),
]
PROBES_ROW1 = [
    (0x87, 0xEB0C, 0xE0,  0),
    (0x87, 0xEB0D, 0xE1,  3),
    (0x87, 0xEB0E, 0xE2,  6),
    (0x87, 0xEB0F, 0xE3,  9),
    (0x86, 0xEAD0, 0xE4, 12),
    (0x86, 0xEAD1, 0xE5, 15),
]
ALL_PROBES = [(b, a, zp, c, 0) for (b,a,zp,c) in PROBES_ROW0] + \
             [(b, a, zp, c, 1) for (b,a,zp,c) in PROBES_ROW1]

def main():
    code = bytearray()
    stub = bytes([0x0B,0x08,0x00,0x00,0x9E,0x32,0x30,0x36,0x31,0x00,0x00,0x00])
    code += stub
    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    emit(0x78, 0x18, 0xFB)
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)
    emit(0xE2, 0x20)

    # Blank rows 0-2
    emit(0xA9, 0x20)
    emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0x04)
    emit(0xE8); emit(0xE0, 0x78, 0x00)
    bpc = addr_of(len(code) + 2); emit(0xD0, (lp - bpc) & 0xFF)

    # Colour row 0 white, row 1 yellow
    for col_lo, col_hi, val in [(0x00, 0xD8, 0x01), (0x28, 0xD8, 0x07)]:
        emit(0xA9, val)
        emit(0xA2, 0x00, 0x00)
        lp = addr_of(len(code))
        emit(0x9D, col_lo, col_hi)
        emit(0xE8); emit(0xE0, 0x28, 0x00)
        bpc = addr_of(len(code) + 2); emit(0xD0, (lp - bpc) & 0xFF)

    # 12 long-LDAs
    for bank, addr, zp, _col, _row in ALL_PROBES:
        a_lo = addr & 0xFF
        a_hi = (addr >> 8) & 0xFF
        emit(0xAF, a_lo, a_hi, bank)
        emit(0x85, zp)

    def paint_hex(zp, col, row):
        screen_addr = 0x0400 + row * 40 + col
        emit(0xA5, zp)
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
        emit(0xC9, 0x0A)
        emit(0x90, 0x05)
        emit(0x38); emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18); emit(0x69, 0x30)
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)
        emit(0xA5, zp)
        emit(0x29, 0x0F)
        emit(0xC9, 0x0A)
        emit(0x90, 0x05)
        emit(0x38); emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18); emit(0x69, 0x30)
        emit(0x8D, (screen_addr+1) & 0xFF, ((screen_addr+1) >> 8) & 0xFF)

    for bank, addr, zp, col, row in ALL_PROBES:
        paint_hex(zp, col, row)

    emit(0xA5, 0xF0)
    emit(0x29, 0x0F)
    emit(0x8D, 0x20, 0xD0)

    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'superram_peek_argptr.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print('Row 0 (file=00 00 00 00 00 00 — any non-zero = runtime override):')
    print('  $87:$EAD8..$EADD')
    print('Row 1 (file=00 00 00 00 00 00):')
    print('  $87:$EB0C..$EB0F, $86:$EAD0..$EAD1')

if __name__ == '__main__':
    sys.exit(main() or 0)
