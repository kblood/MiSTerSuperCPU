"""Disassemble bytes near a target PC in bank $20 of doom.reu, both forward
and a few bytes prior, so we can understand where the DUT halted/branched
when extending the diff harness past the loop-patched prologue.

Usage:
    python3 tools/bank20_disasm_around.py --pc 0x03a5 --before 16 --after 64
"""
from __future__ import annotations

import argparse
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from dis65816 import disasm  # type: ignore  # noqa: E402

REU = REPO / "doom.reu"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", type=lambda s: int(s, 0), default=0x20)
    ap.add_argument("--pc", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--before", type=int, default=16)
    ap.add_argument("--after", type=int, default=128)
    args = ap.parse_args()

    data = REU.read_bytes()
    bank = data[args.bank * 0x10000:(args.bank + 1) * 0x10000]

    start = max(0, args.pc - args.before)

    res = disasm(data, args.bank, start, count=64, m=0, x=0)
    insns = res[0] if isinstance(res, tuple) else res
    for it in insns:
        # `it` shape — try common field names
        if isinstance(it, dict):
            pc = it.get("pc", it.get("addr"))
            text = it.get("text", it.get("mnem", "?"))
            byts = it.get("bytes", "")
        else:
            # tuple/list (pc, bytes, text)
            pc = it[0] if len(it) > 0 else 0
            byts = it[1] if len(it) > 1 else ""
            text = it[2] if len(it) > 2 else "?"
        marker = "<--" if pc == args.pc else ""
        print(f"  ${args.bank:02x}:${pc:04x}  {byts!s:<14}  {text!s:<28}  {marker}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
