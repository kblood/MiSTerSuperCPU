"""Statistical characterization of Asterix C003 hang from per-frame UART.

Per-vblank UART line format:
  A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx W:xxxx L:xx[!.]

Where W: is live PC. We sample once per vblank (~50Hz), so over 30s we see ~1500
PC samples drawn from whatever loop the CPU is executing. With a tight loop the
distribution converges quickly to a stable fingerprint.
"""
import re
import sys
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
    r"L:(?P<l>[0-9A-F]{2})(?P<irq>[!.])"
)

def main(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            m = LINE_RE.search(line)
            if m:
                rows.append(m.groupdict())
    print(f"Parsed {len(rows)} sample lines")
    if not rows:
        return

    # Frame range
    f_first = int(rows[0]["f"], 16)
    f_last  = int(rows[-1]["f"], 16)
    print(f"Frame range: ${rows[0]['f']} -> ${rows[-1]['f']}  ({f_last - f_first} vblanks ~ {(f_last - f_first)/50:.1f}s)")

    # PC distribution
    pcs = Counter(r["w"] for r in rows)
    print(f"\nUnique W:PC values: {len(pcs)}")
    print("Top 15 PC samples:")
    for pc, ct in pcs.most_common(15):
        print(f"  W:{pc}  {ct:5d} ({100*ct/len(rows):5.1f}%)")

    # PBR distribution
    pbrs = Counter(r["k"] for r in rows)
    print(f"\nUnique K:PBR values: {len(pbrs)} -> {dict(pbrs)}")

    # Instruction distribution at sample points
    irs = Counter(r["i"] for r in rows)
    print(f"\nUnique I:opcode values: {len(irs)}")
    print("Top 10:")
    for ir, ct in irs.most_common(10):
        print(f"  I:{ir}  {ct:5d} ({100*ct/len(rows):5.1f}%)")

    # P flag distribution
    ps = Counter(r["p"] for r in rows)
    print(f"\nP flag distribution: {dict(ps)}")
    for p in sorted(ps):
        bits = int(p, 16)
        decoded = []
        if bits & 0x80: decoded.append("N")
        if bits & 0x40: decoded.append("V")
        if bits & 0x20: decoded.append("M")
        if bits & 0x10: decoded.append("X")
        if bits & 0x08: decoded.append("D")
        if bits & 0x04: decoded.append("I")
        if bits & 0x02: decoded.append("Z")
        if bits & 0x01: decoded.append("C")
        print(f"  P:{p} = {'|'.join(decoded) or '(none)'}  count={ps[p]}")

    # SP statistics
    sps = [int(r["s"], 16) for r in rows]
    print(f"\nSP range: ${min(sps):04X} - ${max(sps):04X}")
    print(f"SP page distribution: {Counter(s >> 8 for s in sps)}")
    sub_100 = sum(1 for s in sps if s < 0x100)
    print(f"SP < $0100 (underflow): {sub_100}")

    # E flag
    es = Counter(r["e"] for r in rows)
    print(f"\nE flag: {dict(es)}")

    # Address bus values - what's CPU touching?
    abus = Counter(r["a"] for r in rows)
    print(f"\nUnique A:addr values: {len(abus)}")
    print("Top 15 addresses:")
    for a, ct in abus.most_common(15):
        print(f"  A:{a}  {ct:5d}")

    # IRQ status
    irq_asserted = sum(1 for r in rows if r["irq"] == "!")
    print(f"\nVIC IRQ asserted (trailing !): {irq_asserted} / {len(rows)} ({100*irq_asserted/len(rows):.1f}%)")

    # Cache hits - is anything cached?
    c_vals = set(r["c"] for r in rows)
    n_vals = set(r["n"] for r in rows)
    print(f"\nC: cache-hit counter unique values: {len(c_vals)} -> {sorted(c_vals)[:5]}...")
    print(f"N: enableCpu counter unique values: {len(n_vals)} -> {sorted(n_vals)[:5]}...")

    # T:byte (status register)
    ts = Counter(r["t"] for r in rows)
    print(f"\nT:byte distribution: {dict(ts)}")

    # SP descent pattern over time
    print(f"\nSP samples (every 100th):")
    for i in range(0, len(sps), 100):
        print(f"  frame ${rows[i]['f']}: SP=${sps[i]:04X}  P:{rows[i]['p']}  I:{rows[i]['i']}  A:{rows[i]['a']}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else r"C:\LLM\C64\MiSTerSuperCPU\uart_asterix_c003.log")
