"""Scan a configurable byte range of doom.reu (default bank $20, first 8 KB)
for X-counted / Y-counted tight iteration loops.

Heuristic: locate INX/DEX/INY/DEY bytes followed by BNE/BEQ with a
negative 8-bit offset. These are candidate iteration loops worth
short-circuiting in the cocotb + VICE diff harness so we can push
past Doom's table-init phases without waiting 65536 × loop-body
stepwise captures.

Caveat: the scan walks linearly, treating every byte as a potential
instruction start. That's wrong for variable-width code (M/X mode
transitions). False positives are tolerable because the patch is
applied to BOTH DUT and VICE — if the byte happens to be in the middle
of an unrelated instruction, both sides see the same patched bytes and
the diff stays consistent.
"""
from __future__ import annotations

import argparse
import pathlib

REU = pathlib.Path(__file__).resolve().parents[1] / "doom.reu"

OP_INX, OP_DEX, OP_INY, OP_DEY = 0xE8, 0xCA, 0xC8, 0x88
OP_BNE, OP_BEQ = 0xD0, 0xF0
OP_JMP_ABS = 0x4C
OP_JML = 0x5C
PB_NAME = {OP_INX: "INX", OP_DEX: "DEX", OP_INY: "INY", OP_DEY: "DEY"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", type=lambda s: int(s, 0), default=0x20)
    ap.add_argument("--start", type=lambda s: int(s, 0), default=0x0080)
    ap.add_argument("--end", type=lambda s: int(s, 0), default=0x2000)
    args = ap.parse_args()

    data = REU.read_bytes()
    bank = data[args.bank * 0x10000:(args.bank + 1) * 0x10000]

    hits = []
    for i in range(args.start, min(args.end, 0x10000 - 1)):
        op = bank[i]
        if op not in (OP_BNE, OP_BEQ):
            continue
        rel = bank[i + 1]
        if rel < 0x80:
            continue  # forward branch
        tgt = (i + 2 + (rel - 256)) & 0xFFFF
        prev_byte = bank[i - 1] if i > 0 else 0
        if prev_byte not in PB_NAME:
            continue
        body = i - tgt
        hits.append(("BR", i, op, tgt, body, prev_byte))

    # JMP-back / JML-back loops: target in same bank, within ±0x800 bytes.
    jmp_hits = []
    for i in range(args.start, min(args.end, 0x10000 - 3)):
        op = bank[i]
        if op == OP_JMP_ABS:
            tgt = bank[i + 1] | (bank[i + 2] << 8)
            same_bank = True
            kind_name = "JMP"
        elif op == OP_JML:
            tgt = bank[i + 1] | (bank[i + 2] << 8)
            tgt_pbr = bank[i + 3]
            same_bank = (tgt_pbr == args.bank)
            kind_name = "JML"
        else:
            continue
        if not same_bank:
            continue
        if not (0 <= i - tgt <= 0x0800):
            continue
        if tgt < args.start:
            continue
        body = i - tgt
        jmp_hits.append((kind_name, i, op, tgt, body, 0))

    print(f"Found {len(hits)} INX/DEX-driven loops + {len(jmp_hits)} JMP-back "
          f"candidates in ${args.bank:02x}:${args.start:04x}..${args.end:04x}:")
    print("--- INX/DEX-driven (BNE/BEQ) ---")
    for kind, pc, op, tgt, body, pb in sorted(hits, key=lambda h: -h[4])[:30]:
        op_name = "BNE" if op == OP_BNE else "BEQ"
        print(f"  ${args.bank:02x}:${pc:04x} {op_name} ${tgt:04x}  "
              f"(body={body:3d} bytes, prev={PB_NAME[pb]})")
    print("--- JMP/JML-back ---")
    for kind, pc, op, tgt, body, pb in sorted(jmp_hits, key=lambda h: -h[4])[:30]:
        print(f"  ${args.bank:02x}:${pc:04x} {kind} ${tgt:04x}  (body={body:3d} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
