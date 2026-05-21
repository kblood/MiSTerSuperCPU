#!/usr/bin/env python3
"""
uart_to_trace.py — Convert a captured MiSTer UART log into the trace
format documented in trace_format.md.

The UART log contains per-frame status lines plus, when bug_frozen=1,
TR: extension fields with one ring-buffer entry per frame:

    A:96FF K:00 B:00 S:0144 P:B4 I:FF E:1 F:8E4D T:53 C:0000 N:1381 W:C003 L:00! TR:00 PC:0852 K:00 I:D0 P:37
    ...

This script extracts every TR: entry and emits it in trace format:

    <seq>:<pbr>:<pc>:<ir>:<p>:<sp>

The MiSTer ring buffer does not capture SP per entry, so the SP field is
emitted as 0000. Diff against VICE traces should ignore the SP field
column when this is the source.

Usage:
    uart_to_trace.py <uart_log.txt> <out_trace.txt>
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


TR_RE = re.compile(
    r"TR:([0-9A-Fa-f]{2}) "
    r"PC:([0-9A-Fa-f]{4}) "
    r"K:([0-9A-Fa-f]{2}) "
    r"I:([0-9A-Fa-f]{2}) "
    r"P:([0-9A-Fa-f]{2})"
)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("uart_log", type=Path)
    ap.add_argument("out_trace", type=Path)
    ap.add_argument("--limit", type=int, default=128,
                    help="emit at most this many entries (default 128)")
    args = ap.parse_args()

    if not args.uart_log.exists():
        sys.exit(f"error: {args.uart_log} not found")

    raw = args.uart_log.read_text(encoding="utf-8", errors="replace")
    matches = TR_RE.findall(raw)

    if not matches:
        sys.exit(f"error: no TR: lines in {args.uart_log}")

    seen: dict[int, tuple[str, str, str, str]] = {}
    for tr_idx, pc, pbr, ir, p in matches:
        idx = int(tr_idx, 16)
        if idx not in seen:
            seen[idx] = (pc, pbr, ir, p)

    out = args.out_trace.open("w", encoding="utf-8")
    out.write("TRACE_START\n")
    out.write(f"# from MiSTer UART ring (no SP, SP=0000 placeholder)\n")

    seq = 0
    for idx in sorted(seen.keys()):
        if seq >= args.limit:
            break
        pc, pbr, ir, p = seen[idx]
        out.write(f"{seq}:{pbr.lower()}:{pc.lower()}:{ir.lower()}:{p.lower()}:0000\n")
        seq += 1

    out.close()
    print(f"wrote {seq} trace entries to {args.out_trace}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
