"""hunt_fcee_writers.py — broader scan for $00:$FCEE-$FCF1 writers.

The static `JML/JSL` and 24-bit pointer scans came back zero. Now look
for indirect/computed writers that could land at $FCEE-$FCF1:

1. Long-indexed STA: `9F lo mi bk` (STA $bkmilo,X) where the computed
   target $bkmilo + X could land in $FCEE-$FCF1 for any plausible X.
2. Long-direct STA: `8F lo mi bk` (STA $bkmilo) where bkmilo == $00FCEE+0..3.
3. Indirect-long STA: `87 dp` (STA [dp]) and `97 dp` (STA [dp],Y).
   We can't resolve dp pointer at static-scan time, but we can flag
   these in code regions for later runtime probe.
4. MVN/MVP block-moves: `54 dst src` (MVN) or `44 dst src` (MVP).
   Destination bank dst, source bank src. If dst=$00 and the X/Y
   indices traverse $FCEE..$FCF1, the move overwrites the trampoline.
5. STZ long: `9C lo mi`, `9E lo mi` (STZ abs / STZ abs,X — both 16-bit
   bank=DBR, hard to resolve statically).

Output: per-bank counts plus a sample of the first 20 instances of
each pattern with file offset, bank:address, instruction bytes.
"""

from __future__ import annotations
import sys
from collections import Counter
from pathlib import Path

REU = Path("doom.reu")
if not REU.exists():
    sys.exit(f"missing {REU} (run from repo root)")

img = REU.read_bytes()
print(f"Loaded {REU} ({len(img)} bytes = {len(img)//0x10000} banks)")

# We're hunting writes whose effective address lies in $00:$FCEE..$FCF1.
TARGETS = set(range(0xFCEE, 0xFCF2))   # FCEE, FCEF, FCF0, FCF1
TARGET_ADDR_24 = {0x00FCEE, 0x00FCEF, 0x00FCF0, 0x00FCF1}

# ----------------------------------------------------------------------
# 1. STA $bkmilo (long-direct, no index).  Opcode $8F.
# 2. STA $bkmilo,X (long-indexed). Opcode $9F. We can also flag this
#    when bkmi=$00FC and the offset is in [$EE-X .. $F1-X] for plausible
#    X — but X is unknown statically. Practical heuristic: bkmilo
#    inside [$00FC00..$00FCF1] AND opcode $9F is suspicious.
# ----------------------------------------------------------------------

class Hit:
    __slots__ = ("offset", "bank", "addr", "opcode", "operand", "decode")
    def __init__(self, offset, opcode, operand, decode):
        self.offset = offset
        self.bank = offset >> 16
        self.addr = offset & 0xFFFF
        self.opcode = opcode
        self.operand = operand
        self.decode = decode
    def __repr__(self):
        return (f"${self.bank:02X}:${self.addr:04X}  "
                f"{self.opcode:02X} {self.operand}  {self.decode}")

hits_8F = []      # STA long direct
hits_9F = []      # STA long ,X — only 8F-region matches
hits_87 = []      # STA [dp]
hits_97 = []      # STA [dp],Y
hits_mvn = []     # MVN $00,??
hits_mvp = []     # MVP $00,??
hits_stz_abs = [] # STZ abs into $FCEE region (DBR=$00 path)

for off in range(len(img) - 4):
    op = img[off]

    if op == 0x8F:
        bk = img[off+3]
        mi = img[off+2]
        lo = img[off+1]
        addr24 = (bk << 16) | (mi << 8) | lo
        if addr24 in TARGET_ADDR_24:
            hits_8F.append(Hit(off, op, f"{lo:02X} {mi:02X} {bk:02X}",
                               f"STA ${bk:02X}{mi:02X}{lo:02X}"))

    elif op == 0x9F:
        # STA $bkmilo,X — we don't know X. Flag if bkmi=$00FC (anywhere
        # in the page that contains $FCEE).
        bk = img[off+3]
        mi = img[off+2]
        if bk == 0x00 and mi == 0xFC:
            lo = img[off+1]
            hits_9F.append(Hit(off, op, f"{lo:02X} {mi:02X} {bk:02X}",
                               f"STA ${bk:02X}{mi:02X}{lo:02X},X (X-dependent)"))

    elif op == 0x87:
        # STA [dp]. dp byte at off+1. Cannot resolve dp pointer
        # statically, but worth listing for runtime probe.
        dp = img[off+1]
        hits_87.append(Hit(off, op, f"{dp:02X}", f"STA [${dp:02X}]"))

    elif op == 0x97:
        dp = img[off+1]
        hits_97.append(Hit(off, op, f"{dp:02X}", f"STA [${dp:02X}],Y"))

    elif op == 0x54:
        dst_bank = img[off+1]
        src_bank = img[off+2]
        if dst_bank == 0x00:
            hits_mvn.append(Hit(off, op,
                                f"{dst_bank:02X} {src_bank:02X}",
                                f"MVN dst=$00 src=${src_bank:02X}"))

    elif op == 0x44:
        dst_bank = img[off+1]
        src_bank = img[off+2]
        if dst_bank == 0x00:
            hits_mvp.append(Hit(off, op,
                                f"{dst_bank:02X} {src_bank:02X}",
                                f"MVP dst=$00 src=${src_bank:02X}"))

    elif op == 0x9C or op == 0x9E:
        # STZ abs / STZ abs,X — DBR-relative.
        lo = img[off+1]
        mi = img[off+2]
        addr16 = (mi << 8) | lo
        if 0xFCE0 <= addr16 <= 0xFCFF:
            hits_stz_abs.append(Hit(off, op, f"{lo:02X} {mi:02X}",
                                    f"STZ ${addr16:04X}"
                                    f"{',X' if op == 0x9E else ''}"))

print()
print("=" * 80)
print("Direct hits (provably write to $00:$FCEE-$FCF1):")
print("=" * 80)
print(f"  $8F STA long direct           : {len(hits_8F):>6d}")
print(f"  $9F STA long ,X (X unknown)   : {len(hits_9F):>6d}")
print(f"  $9C/$9E STZ abs into $FCEx    : {len(hits_stz_abs):>6d}")
print()
print("Indirect / computed (need runtime probe):")
print(f"  $87 STA [dp] (dp pointer ?)   : {len(hits_87):>6d}")
print(f"  $97 STA [dp],Y                : {len(hits_97):>6d}")
print(f"  $54 MVN dst=$00               : {len(hits_mvn):>6d}")
print(f"  $44 MVP dst=$00               : {len(hits_mvp):>6d}")

# ----------------------------------------------------------------------
# Per-bank distribution of indirect writes (so we can correlate against
# the runtime trace in `project_doom_runtime_paging_at_4c_d298.md`).
# ----------------------------------------------------------------------

print()
print("=" * 80)
print("Bank distribution of indirect/computed writes:")
print("=" * 80)
all_indirect = hits_87 + hits_97 + hits_mvn + hits_mvp + hits_9F + hits_stz_abs
banks = Counter(h.bank for h in all_indirect)
for b, c in sorted(banks.items())[:80]:
    print(f"  bank ${b:02X}: {c}")

# ----------------------------------------------------------------------
# Print direct hits if any.
# ----------------------------------------------------------------------

def dump(label, hits, n=30):
    print()
    print(f"--- {label} ({len(hits)} total, first {min(n, len(hits))}):")
    for h in hits[:n]:
        print(f"  {h!r}")

dump("$8F STA $00FCEE..F1 (DIRECT)", hits_8F, 50)
dump("$9F STA $00FCxx,X (X-DEPENDENT)", hits_9F, 30)
dump("$9C/$9E STZ $FCExx", hits_stz_abs, 20)
dump("$54 MVN dst=$00 (BLOCK MOVE)", hits_mvn, 30)
dump("$44 MVP dst=$00 (BLOCK MOVE)", hits_mvp, 30)

# Indirect writes are way too numerous for a useful dump; show top
# bank concentration only.
print()
print(f"--- Indirect writes are too numerous to enumerate: "
      f"$87={len(hits_87)} $97={len(hits_97)}")
