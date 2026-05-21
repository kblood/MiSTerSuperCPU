"""check_fcee_banks.py — what's at offset $FCEE across all REU banks?

The J ring captured `FCEE FCEE FCEE FCEE` — 4 fetches of $20 or $22
opcodes at PC=$FCEE in some bank. Could be:
  (a) bank $00:$FCEE with the trampoline latch flipped to RAM-backed,
      RAM byte $20/$22
  (b) bank $XX:$FCEE in some other bank where the underlying SuperRAM
      data happens to be $20 or $22

Scan all 256 banks in doom.reu at offset $FCEE-$FCF1 to find any bank
that has $20 or $22 at $FCEE — that's the actual fetch source if (b).
"""

from __future__ import annotations
from pathlib import Path

img = Path("doom.reu").read_bytes()

print(f"$FCEE byte across 256 REU banks (looking for $20/$22):\n")
hits = []
for bank in range(256):
    base = bank * 0x10000
    fcee = img[base + 0xFCEE]
    fcef = img[base + 0xFCEF]
    fcf0 = img[base + 0xFCF0]
    fcf1 = img[base + 0xFCF1]
    if fcee in (0x20, 0x22):
        hits.append((bank, fcee, fcef, fcf0, fcf1))

print(f"Banks with $20/$22 at offset $FCEE: {len(hits)}")
for bank, ee, ef, f0, f1 in hits[:50]:
    op = "JSR abs" if ee == 0x20 else "JSL long"
    print(f"  ${bank:02X}:$FCEE = {ee:02X} {ef:02X} {f0:02X} {f1:02X}  "
          f"({op} ${f0:02X}{ef:02X}{f1:02X})")

print()
# Also: what's the most common byte at $FCEE across all banks?
from collections import Counter
fcee_dist = Counter(img[b * 0x10000 + 0xFCEE] for b in range(256))
print("Top 10 byte values at offset $FCEE:")
for v, c in fcee_dist.most_common(10):
    print(f"  ${v:02X} : {c} banks")

# Look at total bytes around $FCEE-$FCF1 in each bank that has $20/$22
print()
print("Disasm of suspect banks (10 bytes from $FCEE):")
for bank, ee, ef, f0, f1 in hits[:10]:
    base = bank * 0x10000 + 0xFCE0
    print(f"  bank ${bank:02X} $FCE0..$FCEF: "
          f"{' '.join(f'{b:02X}' for b in img[base:base+16])}")
    base2 = bank * 0x10000 + 0xFCF0
    print(f"  bank ${bank:02X} $FCF0..$FCFF: "
          f"{' '.join(f'{b:02X}' for b in img[base2:base2+16])}")
