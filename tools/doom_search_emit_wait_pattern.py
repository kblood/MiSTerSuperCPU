#!/usr/bin/env python3
"""Search doom.reu for code that EMITS the wait-pattern bytes at runtime.

Hypothesis: the recompiler runtime reads template bytes (from $41:$DBxx or
similar) and writes them to a code cache somewhere. That emit code must:
  - Have `LDA #$DF` / `LDA #$B0` / `LDA #$D0` / `LDA #$FE` immediate loads, OR
  - Read template bytes and long-store to bank $00 (`8F XX XX 00`), AND
  - The output region would then contain the wait pattern at runtime.

If we can find the emitter, we can find the producer of the byte at
$00:$0707+X (the value the wait expects).
"""
from __future__ import annotations
import pathlib
import sys
from collections import Counter

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"


def main():
    data = DOOM_REU.read_bytes()
    print(f"doom.reu: {len(data)} bytes")

    # 1. Long stores into bank $00 (8F LL HH 00) targeting $00:$07xx
    # Pattern: A9 XX (LDA #$XX) followed soon by 8F LL 07 00
    print("\n=== Long stores into $00:$07XX (8F LL 07 00) ===")
    long_store_07 = []
    for i in range(len(data) - 4):
        if data[i] == 0x8F and data[i+2] == 0x07 and data[i+3] == 0x00:
            addr_lo = data[i+1]
            long_store_07.append((i, addr_lo))
    print(f"Total: {len(long_store_07)} long-store-to-$00:$07XX instructions")
    by_lo = Counter(addr_lo for _, addr_lo in long_store_07)
    print(f"Distinct target offsets in $07XX:")
    for lo, n in by_lo.most_common(20):
        print(f"  $07{lo:02X}: {n} stores")

    # 2. Look for any byte sequence that writes the literal `DF 07 07 00` pattern
    # Pattern A: LDA #$DF (A9 DF), STA $XXXX (8D XX YY) or 8F XX YY 00 — actual emit
    # Pattern B: indirect templating: a dispatcher reads bytes from somewhere

    # Find LDA #$DF (A9 DF) followed by some store
    print("\n=== LDA #$DF (A9 DF) and what follows ===")
    a9_df_count = 0
    a9_df_followed_by_store = []
    for i in range(len(data) - 4):
        if data[i] == 0xA9 and data[i+1] == 0xDF:
            a9_df_count += 1
            # Check next few bytes
            next3 = data[i+2:i+5]
            if next3[0] in (0x85, 0x8D, 0x8F, 0x9D, 0x95):  # STA variants
                a9_df_followed_by_store.append((i, next3.hex(' ')))
    print(f"  LDA #$DF: {a9_df_count} total")
    print(f"  followed by STA-variant: {len(a9_df_followed_by_store)}")
    for off, nx in a9_df_followed_by_store[:10]:
        bank = off // 0x10000
        off16 = off % 0x10000
        print(f"    ${bank:02X}:{off16:04X}  A9 DF  {nx}")

    # 3. Search for the 16-bit immediate LDA #$07DF (in 16-bit M mode)
    # That'd emit "DF 07" as part of the wait pattern via STA abs
    print("\n=== LDA #$07DF (16-bit M=0): A9 DF 07 ===")
    cnt_a9_df_07 = sum(1 for i in range(len(data)-3)
                       if data[i] == 0xA9 and data[i+1] == 0xDF and data[i+2] == 0x07)
    print(f"  A9 DF 07: {cnt_a9_df_07} hits")

    # 4. Search for memcpy-style routine that might be emitting templates
    #    Pattern: B7 (LDA [zp],Y) + 97 (STA [zp],Y) — typical 65816 long-pointer copy
    print("\n=== B7 ... 97 (long-indirect load/store) routine markers ===")
    # Most useful: find sequences where B7 (LDA [zp],Y) is followed shortly by 97 (STA [zp],Y)
    b7_97 = 0
    for i in range(len(data) - 8):
        if data[i] == 0xB7:
            # look in next 8 bytes for 97
            if 0x97 in data[i+1:i+9]:
                b7_97 += 1
    print(f"  B7...97 within 8 bytes: {b7_97} occurrences")

    # 5. Dispatch tables: look for runs of 4-byte ptrs that all point into bank $00:$07xx
    # Each ptr is 3 bytes addr + 1 byte pad: XX YY ZZ 00 where ZZ in [$00] and YY=$07
    print("\n=== 4-byte pointers `XX 07 00 00` (likely dispatch table ptrs into $00:$07XX) ===")
    ptr_to_07xx = []
    for i in range(len(data) - 4):
        if data[i+1] == 0x07 and data[i+2] == 0x00 and data[i+3] == 0x00:
            # data[i] is the low byte of $07XX
            lo = data[i]
            ptr_to_07xx.append((i, lo))
    print(f"  Total: {len(ptr_to_07xx)}")
    # Group by lo byte
    lo_counter = Counter(lo for _, lo in ptr_to_07xx)
    print(f"  Distinct low bytes (top 20):")
    for lo, n in lo_counter.most_common(20):
        print(f"    $07{lo:02X}: {n} pointers")

    # 6. Specifically: any long-jump/call into $00:$07xx (other than $0700 entry)?
    # Pattern: 22 (JSL) + 3 bytes addr | 5C (JML) + 3 bytes addr
    # Where addr_hi=$07 and bank=$00
    print("\n=== JSL/JML to $00:$07XX (long calls into code cache) ===")
    for op_label, op in [("JSL (22)", 0x22), ("JML (5C)", 0x5C)]:
        hits = []
        for i in range(len(data) - 4):
            if data[i] == op and data[i+2] == 0x07 and data[i+3] == 0x00:
                hits.append((i, data[i+1]))
        cnt = Counter(lo for _, lo in hits)
        print(f"  {op_label} into $00:$07XX: {len(hits)} hits, distinct tgts:")
        for lo, n in cnt.most_common(10):
            print(f"    $00:$07{lo:02X}: {n} callers")

    # 7. Loader.prg disasm: what's the loader's expected entry point ($07B2 = JML[$04FC])?
    # Check what's at $00:$04FC at the moment of JML (need VICE; off-device we just note)
    print("\n=== Loader entry = JML [$00:$04FC] at $00:$07B2 ===")
    print("  $00:$04FC is the long ptr to the just-loaded section's entry")
    print("  Each FETCH iteration potentially updates the destination [FB:FC:FD]")
    print("  After loop completes, JML [$04FC] jumps to whatever the section's startup ptr is")

    return 0


if __name__ == "__main__":
    sys.exit(main())
