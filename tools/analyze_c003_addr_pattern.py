"""Analyze the address-bus walk at PC=$C003.

If the CPU is locked at PC=$C003 executing SBC long,X (opcode $FF, 4 bytes),
the A-bus we sample is one of: opcode fetch / 3 operand bytes / effective
address / next-instr fetch. By looking at consecutive samples and the values'
ordering we can reconstruct the operand and how X is changing.
"""
import re
from collections import Counter

LINE_RE = re.compile(
    r"A:(?P<a>[0-9A-F]{4}) "
    r"K:(?P<k>[0-9A-F]{2}) "
    r"B:(?P<b>[0-9A-F]{2}) "
    r"S:(?P<s>[0-9A-F]{4}) "
    r"P:(?P<p>[0-9A-F]{2}) "
    r"I:(?P<i>[0-9A-F]{2}) "
)

with open(r"C:\LLM\C64\MiSTerSuperCPU\uart_asterix_c003.log") as fh:
    rows = [m.groupdict() for line in fh if (m := LINE_RE.search(line))]

# Show first 60 raw samples in time order
print("First 60 samples (A, S, P, I):")
for i, r in enumerate(rows[:60]):
    print(f"  {i:3d}  A:{r['a']}  S:{r['s']}  P:{r['p']}  I:{r['i']}")

# Group A-values by I-opcode
print("\nA-values when I=$FF (top 30):")
ff = Counter(r["a"] for r in rows if r["i"] == "FF")
for a, c in ff.most_common(30):
    print(f"  A:{a}  {c}")

print("\nA-values when I=$80 (top 30):")
br = Counter(r["a"] for r in rows if r["i"] == "80")
for a, c in br.most_common(30):
    print(f"  A:{a}  {c}")

# Diff consecutive A-values to see if there's an arithmetic progression
print("\nA-value deltas (sample-to-sample, first 40):")
prev = None
for i, r in enumerate(rows[:40]):
    a = int(r["a"], 16)
    if prev is not None:
        d = (a - prev) & 0xFFFF
        d_signed = d if d < 0x8000 else d - 0x10000
        print(f"  {i:3d}  A:{r['a']}  delta={d_signed:+5d} (0x{d:04X})  I:{r['i']}  S:{r['s']}")
    prev = a

# Look for a-bus values clustered in a window — suggests the operand
print("\nA-value bit ranges:")
print(f"  min=${min(int(r['a'],16) for r in rows):04X}")
print(f"  max=${max(int(r['a'],16) for r in rows):04X}")

# Visualize: bucket by high byte
high_bytes = Counter(r["a"][:2] for r in rows)
print(f"\nA-value high-byte distribution:")
for hb, c in sorted(high_bytes.items()):
    print(f"  ${hb}xx  {c:5d}")
