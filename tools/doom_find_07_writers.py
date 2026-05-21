#!/usr/bin/env python3
"""Locate specific writers/callers into $00:$07XX in doom.reu."""
from __future__ import annotations
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"


def hex_dump(data, off, count=16, prefix=""):
    chunk = data[off:off+count]
    return f"{prefix}{' '.join(f'{b:02X}' for b in chunk)}"


def main():
    data = DOOM_REU.read_bytes()

    # Find the ONE STA $00:$0707 (8F 07 07 00)
    print("=== The ONE long-store to $00:$0707 (8F 07 07 00) ===")
    pat = b"\x8f\x07\x07\x00"
    i = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        bank = j // 0x10000
        off = j % 0x10000
        print(f"  ${bank:02X}:{off:04X}  context:")
        # Print 16 bytes before and 8 after
        ctx_start = max(0, j - 16)
        for cur in range(ctx_start, j + 16, 8):
            chunk = data[cur:cur+8]
            print(f"    REU[${cur:08X}]  {' '.join(f'{b:02X}' for b in chunk)}")
        i = j + 1

    # Find all 7 JSL $00:$0700 (22 00 07 00)
    print("\n=== All JSL $00:$0700 (22 00 07 00) callers ===")
    pat = b"\x22\x00\x07\x00"
    i = 0
    n = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        n += 1
        bank = j // 0x10000
        off = j % 0x10000
        print(f"  caller #{n}: ${bank:02X}:{off:04X}")
        ctx_start = max(0, j - 16)
        ctx_end = min(len(data), j + 16)
        for cur in range(ctx_start, ctx_end, 8):
            chunk = data[cur:cur+8]
            print(f"    REU[${cur:08X}]  {' '.join(f'{b:02X}' for b in chunk)}")
        i = j + 1
        print()

    # Find the ONE JSL $00:$07CD (22 CD 07 00)
    print("\n=== The ONE JSL $00:$07CD (22 CD 07 00) ===")
    pat = b"\x22\xcd\x07\x00"
    i = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        bank = j // 0x10000
        off = j % 0x10000
        print(f"  ${bank:02X}:{off:04X}  context:")
        ctx_start = max(0, j - 32)
        ctx_end = min(len(data), j + 32)
        for cur in range(ctx_start, ctx_end, 16):
            chunk = data[cur:cur+16]
            print(f"    REU[${cur:08X}]  {' '.join(f'{b:02X}' for b in chunk)}")
        i = j + 1

    # Find the 146 stores to $072A — these dominate. What's around the FIRST one?
    print("\n=== First 5 long-stores to $00:$072A (8F 2A 07 00) ===")
    pat = b"\x8f\x2a\x07\x00"
    i = 0
    n = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        n += 1
        bank = j // 0x10000
        off = j % 0x10000
        print(f"  caller #{n}: ${bank:02X}:{off:04X}")
        ctx_start = max(0, j - 8)
        ctx_end = min(len(data), j + 12)
        chunk = data[ctx_start:ctx_end]
        print(f"    bytes: {' '.join(f'{b:02X}' for b in chunk)}")
        i = j + 1
        if n >= 5: break

    # All 41 LDA #$DF — what bank do they live in? (recompiler runtime?)
    print("\n=== All LDA #$DF (A9 DF) — where are they? ===")
    from collections import Counter
    pat = b"\xA9\xDF"
    bank_counter = Counter()
    i = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        bank = j // 0x10000
        bank_counter[bank] += 1
        i = j + 1
    print(f"  Total: {sum(bank_counter.values())}")
    print(f"  Distribution by bank:")
    for bank, n in bank_counter.most_common():
        print(f"    ${bank:02X}: {n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
