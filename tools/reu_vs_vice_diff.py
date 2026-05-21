#!/usr/bin/env python3
"""Bank-by-bank diff: REU source vs VICE post-loader SuperRAM.

Three-way comparison framework for Doom investigation:
  - REU source: doom.reu (16 MB raw input image)
  - VICE post-loader: tools/vice_oracle/gameplay/bank{XX}.bin (per-bank dumps)
  - HW post-loader: dumps via peek-PRG (NOT YET BUILT — placeholder)

VICE-loader and HW-loader should produce IDENTICAL SuperRAM contents IF
the loader runs the same way on both. Since the cocotb harness has
proven loader-body MATCH for 5500+ instructions and the CPU correct
across multiple Doom paths, any HW-vs-VICE divergence is a data-path
issue (REU FETCH corruption, long-store byte error, I/O register read).

Usage:
  reu_vs_vice_diff.py                                    # diff REU vs VICE all banks
  reu_vs_vice_diff.py --bank 87                          # one bank
  reu_vs_vice_diff.py --range 0xEAC0 0xEB00              # one offset range
  reu_vs_vice_diff.py --hw <hwdir>                       # 3-way diff with HW dumps

Output reports {only-vice} and {only-hw} bytes — bytes that the
loader put in place beyond the REU source. These are runtime writes
made BY DOOM CODE after loader exits. They are exactly the data
that can diverge between HW and VICE.
"""
from __future__ import annotations

import argparse
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DOOM_REU = REPO / "doom.reu"
VICE_DIR = REPO / "tools" / "vice_oracle" / "gameplay"


def load_bank_reu(bank: int) -> bytes:
    """Bank XX of doom.reu = bytes [bank*64K, bank*64K+64K)."""
    with open(DOOM_REU, "rb") as f:
        f.seek(bank * 0x10000)
        return f.read(0x10000)


def load_bank_vice(bank: int) -> bytes | None:
    p = VICE_DIR / f"bank{bank:02x}.bin"
    if not p.exists():
        return None
    return p.read_bytes()


def load_bank_hw(hw_dir: pathlib.Path, bank: int) -> bytes | None:
    p = hw_dir / f"bank{bank:02x}.bin"
    if not p.exists():
        return None
    return p.read_bytes()


def diff_bytes(a: bytes, b: bytes, base_addr: int = 0,
               max_show: int = 64):
    """Return list of (addr, a_byte, b_byte) tuples where a != b."""
    out = []
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            out.append((base_addr + i, x, y))
            if len(out) >= max_show:
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", type=lambda s: int(s, 0),
                    help="single bank (0..0x8F)")
    ap.add_argument("--range", nargs=2, type=lambda s: int(s, 0),
                    metavar=("LO", "HI"),
                    help="restrict diff to address range LO..HI within bank")
    ap.add_argument("--hw", type=pathlib.Path,
                    help="HW peek dump dir (bank{XX}.bin layout)")
    ap.add_argument("--max-show", type=int, default=32,
                    help="max diff bytes to show per bank")
    args = ap.parse_args()

    banks = [args.bank] if args.bank is not None else list(range(0, 0x90))

    print("REU vs VICE post-loader SuperRAM diff")
    print("=" * 60)

    total_reu_vs_vice_diff_bytes = 0
    total_vice_vs_hw_diff_bytes = 0

    for bank in banks:
        reu = load_bank_reu(bank)
        vice = load_bank_vice(bank)
        if vice is None:
            continue
        hw = load_bank_hw(args.hw, bank) if args.hw else None

        if args.range is not None:
            lo, hi = args.range
            reu_slice = reu[lo:hi]
            vice_slice = vice[lo:hi]
            base = lo
        else:
            reu_slice = reu
            vice_slice = vice
            base = 0

        rv_diffs = diff_bytes(reu_slice, vice_slice, base, args.max_show)
        if rv_diffs:
            total_reu_vs_vice_diff_bytes += len(rv_diffs)
            print(f"\nBank ${bank:02x} REU-vs-VICE: {len(rv_diffs)} diff "
                  f"bytes shown (base ${base:04x}):")
            for a, x, y in rv_diffs[:args.max_show]:
                print(f"  ${bank:02x}:${a:04x}  REU=${x:02x}  VICE=${y:02x}")

        if hw:
            hw_slice = hw[base:base+len(reu_slice)] if args.range \
                       else hw
            vh_diffs = diff_bytes(vice_slice, hw_slice, base, args.max_show)
            if vh_diffs:
                total_vice_vs_hw_diff_bytes += len(vh_diffs)
                print(f"\nBank ${bank:02x} VICE-vs-HW: {len(vh_diffs)} diff "
                      f"bytes shown (base ${base:04x}):")
                for a, x, y in vh_diffs[:args.max_show]:
                    print(f"  ${bank:02x}:${a:04x}  VICE=${x:02x}  HW=${y:02x}")

    print()
    print("=" * 60)
    print(f"REU-vs-VICE total diff bytes: {total_reu_vs_vice_diff_bytes}")
    if args.hw:
        print(f"VICE-vs-HW  total diff bytes: {total_vice_vs_hw_diff_bytes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
