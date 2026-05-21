#!/usr/bin/env python3
"""Search doom.reu for the exact wait-loop pattern observed at hardware
PB=$41:$DB93 = `df 07 07 00 b0 03 d0 fe`.

If found, report all REU offsets and infer corresponding SuperRAM banks.
If NOT found, hardware halt-PC must be in dynamically-emitted code (JIT
trampoline) OR the PB/PC reading was a latch glitch.
"""
from __future__ import annotations
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"

# Hardware-observed wait-loop bytes
PATTERN = bytes.fromhex("DF 07 07 00 B0 03 D0 FE".replace(" ", ""))

# Variants to also check (in case the wait address differs slightly)
VARIANTS = {
    "DF 07 07 00 B0 03 D0 FE  (canonical)": bytes.fromhex("DF07070000B003D0FE".replace("00", "00", 1)),
    "DF 07 07 00 B0 03 D0 FE  (exact 8 bytes)": bytes.fromhex("DF070700B003D0FE"),
    "DF 07 07 00  alone (CMP only)": bytes.fromhex("DF07070000")[:4],
    "B0 03 D0 FE  alone (BCS+3 BNE-2)": bytes.fromhex("B003D0FE"),
}


def main():
    data = DOOM_REU.read_bytes()
    print(f"doom.reu: {len(data)} bytes ({len(data)//65536} banks of 64K)")

    for label, pat in VARIANTS.items():
        hits = []
        i = 0
        while True:
            j = data.find(pat, i)
            if j < 0:
                break
            hits.append(j)
            i = j + 1
            if len(hits) >= 50:
                break
        print(f"\n{label}: {len(hits)} hits in REU")
        if hits:
            print(f"  first 10 offsets:")
            for h in hits[:10]:
                bank = h // 65536
                off = h % 65536
                print(f"    REU[${h:08X}] = bank ${bank:02X}:${off:04X}")

    # Specifically check if the pattern occurs at REU offset corresponding to
    # bank $41:$DB93. In a direct REU-image-as-SuperRAM mapping:
    #   superram_bank $XX:$YYYY  ↔  REU offset $XX_YYYY  (24-bit)
    target_off = 0x41 * 0x10000 + 0xDB93
    print(f"\nDirect-mapped REU offset for $41:$DB93 = ${target_off:08X}")
    if target_off + 8 < len(data):
        nearby = data[target_off - 4 : target_off + 12]
        print(f"  bytes at REU[${target_off-4:08X}..${target_off+11:08X}]:")
        print(f"    {nearby.hex(' ')}")
    else:
        print(f"  (out of REU range — REU is only 16MB)")

    # Also check $2B:$DB93 (VICE's actual hit) and $20:$DB93
    for pb_label, pb in [("$2B (VICE hit)", 0x2B), ("$20 (VICE hit)", 0x20),
                          ("$41 (HW halt)", 0x41), ("$2A (in-game)", 0x2A),
                          ("$2C", 0x2C)]:
        off = pb * 0x10000 + 0xDB93
        if off + 8 >= len(data):
            print(f"  {pb_label}:$DB93 (REU off ${off:08X}): out-of-range")
            continue
        nearby = data[off - 4 : off + 12]
        print(f"  {pb_label}:$DB93 (REU off ${off:08X}): {nearby.hex(' ')}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
