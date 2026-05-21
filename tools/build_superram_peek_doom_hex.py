#!/usr/bin/env python3
"""Build superram_peek_doom_hex.prg — read 6 SuperRAM bytes at the SAME
offsets the REU probe verified clean, paint as hex digits on row 0.

PRECONDITION: full Doom must have been run BEFORE this probe (so loader.prg
has copied REU→SuperRAM). Sequence:
  1. load doom_full.mgl (or _doom_full_abs.mgl) → loader runs, wedges
     at $2C:$A95C music_num=-9
  2. load superram_peek_doom_hex.mgl → resets core, SuperRAM survives
  3. PRG long-LDAs SuperRAM $20:0000, $20:0001, $40:0000, $40:0001,
     $80:0000, $80:0001 and paints them as hex on row 0

Expected (if loader copy is clean and REU→SuperRAM mapping is 1:1):
  78 D8 FF 8C 53 43

Any divergence localises the bug to loader-phase REU→SuperRAM transfer.
Same memory layout assumption as `tools/build_reu_peek_doom.py`.

Border = SuperRAM $20:$0000 lower nibble = $08 expected.
Row 1 = SuperRAM $86:$0000 / $86:$E000 / $87:$0000 for extra music-area
inspection (offsets chosen near suspected music table at $86:$E9C0).
"""
import os, struct, sys

# Row 0: same 6 anchor bytes the REU probe verified
PROBES_ROW0 = [
    (0x20, 0x0000, 0xF0,  0),  # expected $78
    (0x20, 0x0001, 0xF1,  3),  # expected $D8
    (0x40, 0x0000, 0xF2,  6),  # expected $FF
    (0x40, 0x0001, 0xF3,  9),  # expected $8C
    (0x80, 0x0000, 0xF4, 12),  # expected $53
    (0x80, 0x0001, 0xF5, 15),  # expected $43
]
# Row 1: 6 bytes near music-data table ($86:$E9C0-$EAEF) — observed
# all-zero in v289 SDRAM peek, this confirms via on-chip probe
PROBES_ROW1 = [
    (0x86, 0x0000, 0xE0,  0),  # bank 86 start
    (0x86, 0xE9C0, 0xE1,  3),  # music table head
    (0x86, 0xEACF, 0xE2,  6),  # music table mid
    (0x87, 0x0000, 0xE3,  9),  # bank 87 start
    (0x2B, 0x1A23, 0xE4, 12),  # music check disasm target
    (0x2C, 0xA95C, 0xE5, 15),  # error trap byte (should be $5C = JML)
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

    # Native mode, M=8, X=16
    emit(0x78, 0x18, 0xFB)
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)
    emit(0xE2, 0x20)

    # Blank screen RAM rows 0-2 with spaces
    emit(0xA9, 0x20)
    emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0x04)
    emit(0xE8)
    emit(0xE0, 0x78, 0x00)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (lp - bpc) & 0xFF)

    # Colour row 0 white
    emit(0xA9, 0x01)
    emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0xD8)
    emit(0xE8)
    emit(0xE0, 0x28, 0x00)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (lp - bpc) & 0xFF)

    # Colour row 1 yellow ($07)
    emit(0xA9, 0x07)
    emit(0xA2, 0x00, 0x00)
    lp = addr_of(len(code))
    emit(0x9D, 0x28, 0xD8)
    emit(0xE8)
    emit(0xE0, 0x28, 0x00)
    bpc = addr_of(len(code) + 2)
    emit(0xD0, (lp - bpc) & 0xFF)

    # ---- 12 long-LDA probes ----
    # LDA long ($AF) addr24 → 4-byte instruction
    for bank, addr, zp, _col, _row in ALL_PROBES:
        a_lo = addr & 0xFF
        a_hi = (addr >> 8) & 0xFF
        emit(0xAF, a_lo, a_hi, bank)      # LDA $bank:a_hi:a_lo
        emit(0x85, zp)                    # STA zp

    # ---- For each probe, paint 2 hex digits ----
    def paint_hex(zp, col, row):
        screen_addr = 0x0400 + row * 40 + col
        # high nibble
        emit(0xA5, zp)
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)
        emit(0xC9, 0x0A)
        emit(0x90, 0x05)
        emit(0x38)
        emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18)
        emit(0x69, 0x30)
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)
        # low nibble
        emit(0xA5, zp)
        emit(0x29, 0x0F)
        emit(0xC9, 0x0A)
        emit(0x90, 0x05)
        emit(0x38)
        emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18)
        emit(0x69, 0x30)
        screen_addr2 = screen_addr + 1
        emit(0x8D, screen_addr2 & 0xFF, (screen_addr2 >> 8) & 0xFF)

    for bank, addr, zp, col, row in ALL_PROBES:
        paint_hex(zp, col, row)

    # Border = $F0 lower-nibble
    emit(0xA5, 0xF0)
    emit(0x29, 0x0F)
    emit(0x8D, 0x20, 0xD0)

    # Spin forever
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x80, (spin - bpc) & 0xFF)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'superram_peek_doom_hex.prg')
    with open(out, 'wb') as f: f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes (end ${0x0801+len(code)-1:04X})')
    print()
    print('Row 0 expected (anchor bytes — SHOULD match REU probe):')
    print('  78 D8 FF 8C 53 43')
    print('Row 1 (music-area / error-trap peek):')
    print('  $86:0000  $86:E9C0  $86:EACF  $87:0000  $2B:1A23  $2C:A95C')
    print('  (no a-priori expected values; compare against doom.reu file)')
    print('Border = $08 expected (low nibble of $78).')

if __name__ == '__main__':
    sys.exit(main() or 0)
