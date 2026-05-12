#!/usr/bin/env python3
"""xce_clean2_test.prg — like xce_clean_test but markers OUTSIDE screen RAM.

Markers go to $C300-$C30F instead of $0500-$0502 (screen RAM, overwritten
by BASIC scrolling).

Phases (write a different marker each step so we can recover the sequence
even if some writes are dropped):
  $C300 = $10  (proves PRG started, before XCE)
  $C301 = $33  (A's value before XCE, written via STA in emu)
  $C200 = $00  (target cleared before XCE)
  --- XCE: emu -> native ---
  $C200 = A    (STA $C200 - should be $AA if LDA #$AA fires)
  $C302 = A    (STA $C302 - A's value AFTER the post-XCE LDA+STA)
  --- SEC; XCE: native -> emu ---
  $C303 = $99  (proves we exited native and returned)
  CLI; RTS

Then PEEK 49920..49923 ($C300..$C303) and 49664 ($C200).
"""
import os, struct, sys


def main():
    code = bytearray()
    stub = bytes([0x0B, 0x08, 0x00, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D

    code += bytes([
        # marker: $C300 = $10 (proves PRG ran at all)
        0xA9, 0x10, 0x8D, 0x00, 0xC3,
        # marker: $C301 = $33 = A's value going into XCE
        0xA9, 0x33, 0x8D, 0x01, 0xC3,
        # zero target $C200
        0xA9, 0x00, 0x8D, 0x00, 0xC2,
        # reload known A=$33 for XCE entry (the STA above clobbered A=$33 -> still $33 anyway)
        0xA9, 0x33,
        # enter native
        0x78, 0x18, 0xFB,
        # LDA #$AA   - expected to set A=$AA if not dropped
        0xA9, 0xAA,
        # STA $C200  - target write
        0x8D, 0x00, 0xC2,
        # STA $C302  - capture A AFTER STA (will be same as STA value)
        0x8D, 0x02, 0xC3,
        # leave native
        0x38, 0xFB,
        # marker: $C303 = $99 (proves clean return to emu)
        0xA9, 0x99, 0x8D, 0x03, 0xC3,
        0x58, 0x60,
    ])

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_clean2_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')


if __name__ == '__main__':
    sys.exit(main() or 0)
