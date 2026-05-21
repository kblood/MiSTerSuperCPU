#!/usr/bin/env python3
"""Disassemble bank $41 around $DB96 to understand the wait-loop context.

Scans for what calls/branches to $DB96 (the wait CMP) so we can identify
the producer of $00:$0707+X = the value the wait expects.
"""
from __future__ import annotations
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"


def main():
    data = DOOM_REU.read_bytes()

    # Print bytes around $41:$DB96 (the wait CMP)
    bank = 0x41
    base = bank * 0x10000

    # Pre-context: what code is at $41:$DB60-$DB95
    print("=== $41:$DB60-$DB95 (pre-wait, possibly the producer/setup) ===")
    for off in range(0xDB60, 0xDB96, 16):
        chunk = data[base + off : base + off + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  ${bank:02X}:{off:04X}  {hex_part}  {ascii_part}")

    print("\n=== $41:$DB96-$DBC0 (the wait + post-wait) ===")
    for off in range(0xDB96, 0xDBC0, 16):
        chunk = data[base + off : base + off + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  ${bank:02X}:{off:04X}  {hex_part}  {ascii_part}")

    # Search for any control-flow into $DB96 within bank $41
    # JSR abs (20 96 DB), JMP abs (4C 96 DB), BNE/BEQ/etc back to $DB96
    print("\n=== Searches for callers/branches into $DB96 ===")

    # In bank $41, JSR $DB96 = 20 96 DB
    for pattern_label, pattern in [
        ("JSR $DB96 (20 96 DB)", b"\x20\x96\xdb"),
        ("JMP $DB96 (4C 96 DB)", b"\x4c\x96\xdb"),
        ("JSL $41:$DB96 (22 96 DB 41)", b"\x22\x96\xdb\x41"),
        ("JML $41:$DB96 (5C 96 DB 41)", b"\x5c\x96\xdb\x41"),
        ("Long-PER #$DB96 (62 96 DB)", b"\x62\x96\xdb"),
    ]:
        bank_data = data[base : base + 0x10000]
        hits = []
        i = 0
        while True:
            j = bank_data.find(pattern, i)
            if j < 0: break
            hits.append(j)
            i = j + 1
        print(f"  {pattern_label} in bank ${bank:02X}: {len(hits)} hits")
        for h in hits[:5]:
            ctx_lo = max(0, h - 8)
            ctx_hi = min(0x10000, h + 8)
            ctx = bank_data[ctx_lo:ctx_hi]
            print(f"    ${bank:02X}:{h:04X}  context: {ctx.hex(' ')}")

    # Look for ANY JSL/JML to bank $41 from anywhere in REU
    print("\n=== Cross-bank entries to bank $41 (any addr) ===")
    for opcode_label, opcode in [("JSL $41:xxxx (22)", 0x22), ("JML $41:xxxx (5C)", 0x5c)]:
        hits = []
        for i in range(len(data) - 4):
            if data[i] == opcode and data[i+3] == 0x41:
                tgt = data[i+1] | (data[i+2] << 8)
                hits.append((i, tgt))
        print(f"  {opcode_label}: {len(hits)} hits across all 256 banks")
        # Group by target addr
        from collections import Counter
        tgt_counter = Counter(t for _, t in hits)
        print(f"  Top 10 distinct target addresses:")
        for tgt, n in tgt_counter.most_common(10):
            print(f"    ${tgt:04X}: {n} callers")
        # Look specifically for targets near $DB96
        near = [h for h in hits if 0xDB80 <= h[1] <= 0xDBC0]
        print(f"  Targets in $DB80-$DBC0 range: {len(near)}")
        for off, tgt in near[:5]:
            src_bank = off // 0x10000
            src_off = off % 0x10000
            print(f"    from ${src_bank:02X}:{src_off:04X} -> $41:${tgt:04X}")

    # Find what writes $00:$0707-$07FF in REU (long stores)
    print("\n=== Search for `8F 07 07 00` (STA $00:$0707) and STZ $0707 ===")
    for label, pattern in [
        ("STA $00:$07XX (8F XX 07 00)", lambda d, i: d[i] == 0x8F and d[i+2] == 0x07 and d[i+3] == 0x00),
        ("STA abs $07XX (8D XX 07)", lambda d, i: d[i] == 0x8D and d[i+2] == 0x07),
        ("STZ abs $07XX (9C XX 07)", lambda d, i: d[i] == 0x9C and d[i+2] == 0x07),
    ]:
        hits = []
        for i in range(len(data) - 4):
            if label.startswith("STA $00") and i + 4 <= len(data):
                if pattern(data, i):
                    addr_lo = data[i+1]
                    if 0xB0 <= addr_lo <= 0xC0:  # near our wait byte $07B6
                        hits.append((i, addr_lo))
            elif i + 3 <= len(data):
                if pattern(data, i):
                    addr_lo = data[i+1]
                    if 0xB0 <= addr_lo <= 0xC0:
                        hits.append((i, addr_lo))
            if len(hits) > 100:
                break
        print(f"  {label} (filtered to addr_lo $B0-$C0): {len(hits)} hits")
        for off, addr_lo in hits[:8]:
            bank = off // 0x10000
            off16 = off % 0x10000
            print(f"    ${bank:02X}:{off16:04X} writes $00:$07{addr_lo:02X}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
