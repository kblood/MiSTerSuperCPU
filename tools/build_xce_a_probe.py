#!/usr/bin/env python3
"""xce_a_probe.prg — track A's value precisely at each step around XCE.

Markers (all in $C300+ to avoid screen RAM):
  $C300 = STA right after CLC (BEFORE XCE)  -- A should be $33
  $C200 = STA RIGHT AFTER XCE (no LDA in between) -- A should still be $33
  $C301 = LDA #$AA; STA       -- if no drop, A=$AA, $C301=$AA
  $C302 = LDA #$BB; STA       -- second LDA, $C302 should be $BB
  $C303 = LDA #$CC; STA       -- third LDA, $C303 should be $CC
  $C304 = right after SEC; XCE; STA (still A=$CC if preserved)
  $C305 = LDA #$99; STA       -- back in emu mode, $C305 should be $99

So we can see:
  - $C200 = $33  -> A preserved through XCE
  - $C200 != $33 -> XCE itself corrupts A
  - $C301..3 mismatch -> LDAs are being dropped
"""
import os, struct, sys


def main():
    code = bytearray()
    stub = bytes([0x0B, 0x08, 0x00, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])
    code += stub
    assert 0x0801 + len(code) == 0x080D

    code += bytes([
        # zero all targets first
        0xA9, 0x00,
        0x8D, 0x00, 0xC2,        # $C200=0
        0x8D, 0x00, 0xC3,        # $C300=0
        0x8D, 0x01, 0xC3,        # $C301=0
        0x8D, 0x02, 0xC3,        # $C302=0
        0x8D, 0x03, 0xC3,        # $C303=0
        0x8D, 0x04, 0xC3,        # $C304=0
        0x8D, 0x05, 0xC3,        # $C305=0
        # known A=$33
        0xA9, 0x33,
        # PRE-XCE: write A to $C300 (should be $33)
        0x8D, 0x00, 0xC3,
        # enter native
        0x78,                    # SEI
        0x18,                    # CLC
        0xFB,                    # XCE -> native
        # IMMEDIATELY write A to $C200 (no LDA in between)
        0x8D, 0x00, 0xC2,
        # 1st LDA in native
        0xA9, 0xAA,
        0x8D, 0x01, 0xC3,        # $C301 = ?
        # 2nd LDA in native (should always succeed if drop is one-shot)
        0xA9, 0xBB,
        0x8D, 0x02, 0xC3,        # $C302 = $BB
        # 3rd LDA in native
        0xA9, 0xCC,
        0x8D, 0x03, 0xC3,        # $C303 = $CC
        # leave native
        0x38,                    # SEC
        0xFB,                    # XCE -> emu
        # IMMEDIATELY write A to $C304 (no LDA between SEC;XCE and STA)
        0x8D, 0x04, 0xC3,
        # post-emu LDA
        0xA9, 0x99,
        0x8D, 0x05, 0xC3,        # $C305 = ?
        0x58,                    # CLI
        0x60,                    # RTS
    ])

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xce_a_probe.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes, end=${0x0801+len(code)-1:04X}')


if __name__ == '__main__':
    sys.exit(main() or 0)
