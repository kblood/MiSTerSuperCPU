"""Analyze hardware UART captured from cold load_core through asterix MGL load.

Goal: see PC trajectory from boot through hang. Identify the divergence point
where hardware leaves the legitimate execution path.
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
    r"E:(?P<e>[01]) "
    r"F:(?P<f>[0-9A-F]{4}) "
    r"T:(?P<t>[0-9A-F]{2}) "
    r"C:(?P<c>[0-9A-F]{4}) "
    r"N:(?P<n>[0-9A-F]{4}) "
    r"W:(?P<w>[0-9A-F]{4}) "
)

with open(r"C:\LLM\C64\MiSTerSuperCPU\uart_asterix_freshrun.uart") as fh:
    rows = [m.groupdict() for line in fh if (m := LINE_RE.search(line))]

print(f"Parsed {len(rows)} samples")

# Show every 20th sample to see trajectory
print("\nTrajectory (every 25th sample):")
print(f"  {'idx':>5} {'F':>5} {'W:PC':>6} {'I':>4} {'P':>4} {'S':>6} {'A':>6} {'K':>3}")
for i in range(0, len(rows), 25):
    r = rows[i]
    print(f"  {i:5d} {r['f']:>5} {r['w']:>6} {r['i']:>4} {r['p']:>4} {r['s']:>6} {r['a']:>6} {r['k']:>3}")

# Find first/last index where W != C003
print("\nW:PC unique values and first occurrence:")
seen = {}
for i, r in enumerate(rows):
    pc = r["w"]
    if pc not in seen:
        seen[pc] = i
for pc, idx in sorted(seen.items(), key=lambda x: x[1]):
    f_at = rows[idx]["f"]
    print(f"  W:{pc} first at idx={idx} F=${f_at}")

# Cluster: how long was each PC sustained?
print(f"\nW:PC distribution overall:")
ws = Counter(r["w"] for r in rows)
for w, c in ws.most_common(10):
    print(f"  W:{w}  {c:5d} ({100*c/len(rows):5.1f}%)")
