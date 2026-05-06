"""Scan a doom.reu bank for outgoing JML/JSL targets and outgoing
long-abs reads (af/9f/bf opcodes), so the diff harness operator can plan
which extra banks need loading.

Usage:
    python3 tools/bank_jml_trail.py --bank 0x2d --start 0x06a0 --end 0x0700
"""
from __future__ import annotations

import argparse
import pathlib
from collections import Counter

REU = pathlib.Path(__file__).resolve().parents[1] / "doom.reu"

OP_JML, OP_JSL = 0x5C, 0x22
OP_LDA_AL, OP_STA_AL, OP_LDA_AL_X = 0xAF, 0x8F, 0xBF
OP_STA_AL_X = 0x9F


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--start", type=lambda s: int(s, 0), default=0x0000)
    ap.add_argument("--end", type=lambda s: int(s, 0), default=0x10000)
    args = ap.parse_args()

    data = REU.read_bytes()
    bank = data[args.bank * 0x10000:(args.bank + 1) * 0x10000]
    end = min(args.end, 0x10000 - 4)

    out_jmls = []
    long_reads = Counter()
    long_writes = Counter()

    for pc in range(args.start, end):
        op = bank[pc]
        if op in (OP_JML, OP_JSL):
            tgt_pc = bank[pc + 1] | (bank[pc + 2] << 8)
            tgt_pbr = bank[pc + 3]
            kind = "JML" if op == OP_JML else "JSL"
            if tgt_pbr != args.bank:
                out_jmls.append((pc, kind, tgt_pbr, tgt_pc))
        elif op in (OP_LDA_AL, OP_LDA_AL_X):
            addr = bank[pc + 1] | (bank[pc + 2] << 8)
            tgt_pbr = bank[pc + 3]
            long_reads[tgt_pbr] += 1
        elif op in (OP_STA_AL, OP_STA_AL_X):
            addr = bank[pc + 1] | (bank[pc + 2] << 8)
            tgt_pbr = bank[pc + 3]
            long_writes[tgt_pbr] += 1

    print(f"=== Bank ${args.bank:02x} ${args.start:04x}..${args.end:04x} "
          f"trail scan ===")
    print(f"\nOutgoing JML/JSL ({len(out_jmls)}):")
    for pc, kind, tpbr, tpc in out_jmls[:40]:
        print(f"  ${args.bank:02x}:${pc:04x}  {kind} ${tpbr:02x}:${tpc:04x}")
    print(f"\nLong-abs read banks (LDA al / LDA al,X):")
    for pbr, n in sorted(long_reads.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  ${pbr:02x} = {n} occurrences")
    print(f"\nLong-abs write banks (STA al / STA al,X):")
    for pbr, n in sorted(long_writes.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  ${pbr:02x} = {n} occurrences")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
