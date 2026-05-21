#!/usr/bin/env python3
"""Parse v341 UART output. v341 added two new fields per vblank line:

  - 1D:####  (bytes 194-201)  — last cpuDi/cpuDo at bank-$00:$1D02 / $1D04
  - D6:##    (bytes 220-225)  — last cpuDo to $D016

Usage:  python tools/parse_v341_uart.py tools/doom_full/v341_uart.txt

Output: summary of unique 1D values, unique D6 values, D1/D8/C2/D6 evolution,
and whether the $1D02/$1D04 handshake bytes are toggling.
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path


PATTERNS = {
    "F":   re.compile(r"F:([0-9a-fA-F]{4})"),
    "PC":  re.compile(r"PC:([0-9a-fA-F]{6})"),
    "1D":  re.compile(r"1D:([0-9a-fA-F]{4})"),
    "D1":  re.compile(r"D1:([0-9a-fA-F]{2})"),
    "D8":  re.compile(r"D8:([0-9a-fA-F]{2})"),
    "C2":  re.compile(r"C2:([0-9a-fA-F]{2})"),
    "D6":  re.compile(r"D6:([0-9a-fA-F]{2})"),
    "VW":  re.compile(r"VW:([0-9a-fA-F]{4})"),
    "AC":  re.compile(r"AC:([0-9a-fA-F]{4})"),
    "IF":  re.compile(r"IF:([0-9a-fA-F]{4})"),
}


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    path = Path(argv[1])
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 1

    raw = path.read_bytes().decode("latin-1", errors="replace")
    lines = [ln for ln in raw.splitlines() if "PC:" in ln and "1D:" in ln]

    if not lines:
        print(f"no v341 lines found in {path} (need both 'PC:' and '1D:')")
        return 1

    print(f"{path}: {len(lines)} v341 lines")
    print()

    counts: dict[str, Counter[str]] = {k: Counter() for k in PATTERNS}
    first: dict[str, str] = {}
    last: dict[str, str] = {}

    for ln in lines:
        for key, pat in PATTERNS.items():
            m = pat.search(ln)
            if m:
                v = m.group(1).lower()
                counts[key][v] += 1
                if key not in first:
                    first[key] = v
                last[key] = v

    print("=== Per-field unique-value summary ===")
    for key in ["F", "PC", "1D", "D1", "D8", "C2", "D6", "VW", "AC", "IF"]:
        c = counts[key]
        if not c:
            continue
        top = c.most_common(8)
        unique = len(c)
        print(f"  {key:3}: {unique:4d} unique values; first={first.get(key)} last={last.get(key)}")
        print(f"       top: {top}")

    print()
    print("=== Hypothesis discrimination ===")
    d6 = counts["D6"]
    if d6:
        d6_d8_seen = any(v == "d8" for v in d6)
        if d6_d8_seen:
            print("  D6=$D8 SEEN -> MCM bitmap mode reached. Bitmap-fill code IS running.")
        else:
            print(f"  D6=$D8 NOT seen (values: {sorted(d6.keys())}) -> bitmap-fill code likely never reached.")

    onedeux = counts["1D"]
    if onedeux:
        if len(onedeux) == 1:
            (val,) = onedeux.keys()
            print(f"  1D static at one value (${val}) -> page-flip handshake not toggling.")
            print(f"    If high 2 nibbles == low 2 nibbles, page-flip code is stuck on bank 1.")
        else:
            print(f"  1D has {len(onedeux)} distinct values -> handshake IS toggling.")
            for v, ct in sorted(onedeux.items(), key=lambda kv: -kv[1])[:6]:
                hi = v[:2]
                lo = v[2:]
                print(f"    ${v}: $1D02=${hi}, $1D04=${lo}, count={ct}")

    c2 = counts["C2"]
    if c2:
        if len(c2) == 1:
            (val,) = c2.keys()
            print(f"  DD00 (C2) static at ${val} -> VIC bank NOT page-flipping.")
        else:
            print(f"  DD00 (C2) has {len(c2)} distinct values -> VIC bank page-flip IS happening.")

    irq = counts["IF"]
    if irq and len(irq) >= 2:
        vals = sorted(irq.keys(), key=lambda v: int(v, 16))
        first_if = int(vals[0], 16)
        last_if = int(vals[-1], 16)
        delta = (last_if - first_if) & 0xFFFF
        print(f"  IF (IRQ counter) range ${vals[0]}..${vals[-1]} = +{delta} IRQs across capture")
        if delta < 10:
            print(f"    -> IRQ STARVED. Expected ~60Hz * seconds. IRQ source likely masked.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
