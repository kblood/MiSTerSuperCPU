#!/usr/bin/env python3
"""
vice_diff.py — Diff two PC trace files in the format documented in
trace_format.md (one instruction-fetch line per row, fields separated
by colons).

Usage:
    vice_diff.py <vice_trace.txt> <ours_trace.txt> [--context N]

Output:
    First N lines that match (sanity check).
    First divergent line from each side, with up to N surrounding lines
    of context (default 32). Field-by-field diff to highlight whether
    PC, IR, P, or SP is the differing axis.
    Summary: total matched, total compared, divergence position.

Exit code:
    0 — traces match for the full overlap (no divergence)
    1 — divergence found
    2 — input parse error or missing file
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class TraceLine:
    seq: int
    pbr: int
    pc: int
    ir: int
    p: int
    sp: int
    raw: str

    @classmethod
    def parse(cls, raw: str) -> Optional["TraceLine"]:
        raw = raw.strip()
        if not raw or raw.startswith("#") or raw.startswith("TRACE_"):
            return None
        parts = raw.split(":")
        if len(parts) != 6:
            return None
        try:
            return cls(
                seq=int(parts[0], 10),
                pbr=int(parts[1], 16),
                pc=int(parts[2], 16),
                ir=int(parts[3], 16),
                p=int(parts[4], 16),
                sp=int(parts[5], 16),
                raw=raw,
            )
        except ValueError:
            return None


def load_trace(path: Path) -> list[TraceLine]:
    if not path.exists():
        raise SystemExit(f"error: trace file not found: {path}")
    out: list[TraceLine] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = TraceLine.parse(raw)
            if line is not None:
                out.append(line)
    if not out:
        raise SystemExit(f"error: no parseable trace lines in {path}")
    return out


def compare(vice: list[TraceLine], ours: list[TraceLine],
            pc_only: bool = False) -> Optional[int]:
    """Returns the index of the first divergent line, or None if traces match.

    When pc_only=True, compare only PC (and PBR). This is needed when one side
    (e.g. VICE text-monitor `trace exec`) doesn't emit P/SP per-instruction,
    and when one side has IR-skew (e.g. our P65C816 dbg_ir reports the
    PREVIOUSLY decoded opcode at the cycle of a new fetch).
    """
    n = min(len(vice), len(ours))
    for i in range(n):
        v, o = vice[i], ours[i]
        if pc_only:
            if (v.pbr, v.pc) != (o.pbr, o.pc):
                return i
        else:
            if (v.pbr, v.pc, v.ir, v.p, v.sp) != (o.pbr, o.pc, o.ir, o.p, o.sp):
                return i
    if len(vice) != len(ours):
        return n
    return None


def auto_align(vice: list[TraceLine], ours: list[TraceLine],
               window: int = 16) -> tuple[int, int]:
    """Find offsets (vice_skip, ours_skip) where PC sequences first match for
    `window` consecutive entries. Returns (0, 0) if no alignment found.
    """
    max_off = min(8, min(len(vice), len(ours)) - window)
    for vs in range(max_off + 1):
        for os in range(max_off + 1):
            if all(vice[vs + k].pc == ours[os + k].pc for k in range(window)):
                return vs, os
    return 0, 0


def field_diff(v: TraceLine, o: TraceLine) -> list[str]:
    diffs = []
    if v.pbr != o.pbr:
        diffs.append(f"PBR vice={v.pbr:02x} ours={o.pbr:02x}")
    if v.pc != o.pc:
        diffs.append(f"PC vice={v.pc:04x} ours={o.pc:04x}")
    if v.ir != o.ir:
        diffs.append(f"IR vice={v.ir:02x} ours={o.ir:02x}")
    if v.p != o.p:
        diffs.append(f"P vice={v.p:02x} ours={o.p:02x}")
    if v.sp != o.sp:
        diffs.append(f"SP vice={v.sp:04x} ours={o.sp:04x}")
    return diffs


def fmt_line(t: TraceLine) -> str:
    return f"  {t.seq:>8d} K:{t.pbr:02x} PC:{t.pc:04x} IR:{t.ir:02x} P:{t.p:02x} SP:{t.sp:04x}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vice", type=Path, help="VICE trace file")
    ap.add_argument("ours", type=Path, help="our (sim/hw) trace file")
    ap.add_argument("--context", type=int, default=32,
                    help="lines of context around the divergence (default 32)")
    ap.add_argument("--pc-only", action="store_true",
                    help="compare PC only (skip IR/P/SP — needed when one side lacks them)")
    ap.add_argument("--align", action="store_true",
                    help="auto-align traces by PC before diffing")
    args = ap.parse_args()

    vice = load_trace(args.vice)
    ours = load_trace(args.ours)

    print(f"# vice trace: {len(vice)} lines from {args.vice}")
    print(f"# ours trace: {len(ours)} lines from {args.ours}")

    if args.align:
        vs, os_ = auto_align(vice, ours)
        if vs or os_:
            print(f"# auto-align: skipping vice[{vs}], ours[{os_}]")
            vice = vice[vs:]
            ours = ours[os_:]

    div = compare(vice, ours, pc_only=args.pc_only)
    if div is None:
        print(f"\nMATCH — traces agree for all {len(vice)} compared lines.")
        return 0

    print(f"\nDIVERGENCE at trace index {div}")

    # Print context window
    start = max(0, div - args.context)
    end_v = min(len(vice), div + args.context + 1)
    end_o = min(len(ours), div + args.context + 1)

    print(f"\n--- VICE [{start}..{end_v}) ---")
    for i in range(start, end_v):
        marker = " >>>" if i == div else "    "
        print(f"{marker}{fmt_line(vice[i])}")

    print(f"\n--- OURS [{start}..{end_o}) ---")
    for i in range(start, end_o):
        marker = " >>>" if i == div else "    "
        print(f"{marker}{fmt_line(ours[i])}")

    if div < len(vice) and div < len(ours):
        diffs = field_diff(vice[div], ours[div])
        print("\nField diffs at divergence:")
        for d in diffs:
            print(f"  {d}")
    else:
        which = "vice" if div >= len(ours) else "ours"
        print(f"\n{which} trace ended early at index {div}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
