#!/usr/bin/env python3
"""Peek SuperRAM at $5C:$B540..$B54F (16 bytes around the corruption site).

doom.reu file bytes at this range:
  $5C:$B540: 03 65 66 66 65 65 03 03 03 6A 6C 05 08 08 08 08

If hardware screen shows these bytes -> only $B546 (or a few bytes)
corrupted in our run.

If hardware screen shows many different values -> systematic corruption
during the loader populate.

The PRG loads on top of the (presumed wedged) Doom runtime, so the data
we read is whatever Doom (or our HW) currently has in SuperRAM. The
v320 capture saw $F7 read AT THE MOMENT of the bad LDA at $2B:$B10C;
by the time this peek runs, $5C:$B546 may have been overwritten by
the JIT shim (v319: 6535 writes of $F7 to bank $5C during run).
So this peek tells us the FINAL state at wedge, not the corruption
moment specifically. Still informative for scope.

Paints 16 bytes as hex on row 0, plus byte at $5C:$B546 (the bad
address) on border.
"""
import os, struct, sys


def main():
    code = bytearray()
    stub = bytes([0x0B, 0x08, 0x00, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    code += stub

    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    emit(0x78, 0x18, 0xFB)
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)
    emit(0xE2, 0x20)

    # Clear row 0
    emit(0xA9, 0x20); emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0x04)
    emit(0xE8); emit(0xE0, 0x28, 0x00)
    bpc = addr_of(len(code) + 2); emit(0xD0, (lp - bpc) & 0xFF)

    emit(0xA9, 0x01); emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)
    emit(0xE8); emit(0xE0, 0x28, 0x00)
    bpc = addr_of(len(code) + 2); emit(0xD0, (lp - bpc) & 0xFF)

    def lda_long_to_zp(bank, lo, hi, zp):
        # LDA $bank:$hi$lo (4-byte AF) then STA zp
        emit(0xAF, lo, hi, bank)
        emit(0x85, zp)

    def paint_byte(zp, col):
        screen_addr = 0x0400 + col
        emit(0xA5, zp)
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
        emit(0xC9, 0x0A); emit(0x90, 0x05); emit(0x38); emit(0xE9, 0x09)
        emit(0x80, 0x03); emit(0x18); emit(0x69, 0x30)
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)
        emit(0xA5, zp); emit(0x29, 0x0F)
        emit(0xC9, 0x0A); emit(0x90, 0x05); emit(0x38); emit(0xE9, 0x09)
        emit(0x80, 0x03); emit(0x18); emit(0x69, 0x30)
        emit(0x8D, (screen_addr + 1) & 0xFF, ((screen_addr + 1) >> 8) & 0xFF)

    # Peek 16 bytes $5C:$B540..$B54F into ZP $40..$4F
    base = 0xB540
    bank = 0x5C
    for i in range(16):
        addr = base + i
        lda_long_to_zp(bank, addr & 0xFF, (addr >> 8) & 0xFF, 0x40 + i)

    # Paint 16 bytes as hex pairs, 2 cols apart (cols 0,2,4,...,30)
    for i in range(16):
        col = i * 2
        paint_byte(0x40 + i, col)

    # Border = LO nibble of byte at $5C:$B546 (offset +6 in our buffer = $46)
    emit(0xA5, 0x46); emit(0x29, 0x0F); emit(0x8D, 0x20, 0xD0)

    # Spin
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'peek_5cb540.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')
    print()
    print('Expected (file): 03 65 66 66 65 65 03 03 03 6A 6C 05 08 08 08 08')
    print('  byte at $5C:$B546 (col 12-13 on screen) = $03 (file)')
    print('                                          = $F7 (HW corruption)')
    print('Border color = LO nibble of byte at $B546:')
    print('  $03 -> 3 (cyan)')
    print('  $F7 -> 7 (yellow)')


if __name__ == '__main__':
    sys.exit(main() or 0)
