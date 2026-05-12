#!/usr/bin/env python3
"""Combined PRG: runs full Doom loader, then peeks bank $00 $0090..$009F
(motherboard RAM zero-page).

Replaces v321/v322 chain's "what's at $5C:$B546" probe with "what's at
$0090 right after loader, before Doom runs". v325 (filter $F6 writes
to $0090) NEVER FIRED during Doom runtime, but v324 proved ZP $90 = $F6
at the moment Doom reads it. So $90 = $F6 must come from EITHER:
- Loader-phase write (catch by this probe)
- DMA write during Doom (CPU filter misses)
- BRAM read corruption

This probe distinguishes the loader-phase hypothesis from the others.

If $90 = $00 here -> loader does NOT set $90 -> corruption is during
                    Doom (DMA or BRAM-read-bug).
If $90 = $F6 here -> loader IS the source -> investigate loader's
                    ZP usage / REU DMA pattern.

Border: LO nibble of byte at $0090.
"""
import os, struct, sys


def main():
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', 'loader.prg')
    src = os.path.abspath(src)
    with open(src, 'rb') as f:
        prg = bytearray(f.read())
    assert len(prg) == 254, f'loader.prg should be 254 bytes, got {len(prg)}'

    base_run = 0x08FD  # same as loader_then_peek (peek bytes append at $08FD)

    # Patch JML [$04FC] (at PRG offset $D3 = run addr $07B2) to JMP $08FD.
    patch_off = 0xD3
    assert bytes(prg[patch_off:patch_off+3]) == bytes([0xDC, 0xFC, 0x04]), \
        'JML [$04FC] not at expected offset'
    prg[patch_off:patch_off+3] = bytes([0x4C, base_run & 0xFF, (base_run >> 8) & 0xFF])

    peek = bytearray()
    def emit(*bs):
        peek.extend(bs)

    emit(0x78)            # SEI
    emit(0xA9, 0x35)      # LDA #$35
    emit(0x85, 0x01)      # STA $01

    emit(0x18)            # CLC
    emit(0xFB)            # XCE
    emit(0xEA, 0xEA, 0xEA, 0xEA)
    emit(0xC2, 0x10)      # REP #$10
    emit(0xE2, 0x20)      # SEP #$20

    # Clear row 0
    emit(0xA9, 0x20)
    emit(0xA2, 0x00, 0x00)
    clr_start = base_run + len(peek)
    emit(0x9D, 0x00, 0x04)
    emit(0xE8)
    emit(0xE0, 0x28, 0x00)
    rel_back = (clr_start - (base_run + len(peek) + 2)) & 0xFF
    emit(0xD0, rel_back)

    emit(0xA9, 0x01)
    emit(0xA2, 0x00, 0x00)
    cclr_start = base_run + len(peek)
    emit(0x9D, 0x00, 0xD8)
    emit(0xE8)
    emit(0xE0, 0x28, 0x00)
    rel_back = (cclr_start - (base_run + len(peek) + 2)) & 0xFF
    emit(0xD0, rel_back)

    # Read $00:$0090..$009F via LDA long into ZP $40..$4F
    bank = 0x00
    addr_base = 0x0090
    for i in range(16):
        addr = addr_base + i
        emit(0xAF, addr & 0xFF, (addr >> 8) & 0xFF, bank)
        emit(0x85, 0x40 + i)

    # Paint each byte as 2 hex chars
    def paint(zp, col):
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

    for i in range(16):
        paint(0x40 + i, i * 2)

    # Border = LO nibble of byte at $0090 (offset 0 in our buffer = ZP $40)
    emit(0xA5, 0x40); emit(0x29, 0x0F); emit(0x8D, 0x20, 0xD0)

    spin = base_run + len(peek)
    rel_back = (spin - (base_run + len(peek) + 2)) & 0xFF
    emit(0x80, rel_back)

    prg.extend(peek)
    print(f'peek body: {len(peek)} bytes at run-addr ${base_run:04X}')

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'loader_then_peek_zp.prg')
    with open(out, 'wb') as f:
        f.write(bytes(prg))
    print(f'Wrote {out}: {len(prg)} bytes')
    print()
    print('Standalone (no loader) showed $0090 = $00 on fresh boot.')
    print('Post-loader expected:')
    print('  $90 = $00 -> loader does NOT touch $90; runtime is the source.')
    print('  $90 = $F6 -> loader leaves $F6; investigate loader/REU DMA path.')


if __name__ == '__main__':
    sys.exit(main() or 0)
