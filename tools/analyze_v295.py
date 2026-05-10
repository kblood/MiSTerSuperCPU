"""analyze_v295.py — compare v294 vs v295 UART N-field distribution.

v294 with the I-flag gate showed N (= pc_main_r) frozen at $41:$DB93.
If v295's PB-based gate exposes main-thread fetches, the N field
should now vary across samples. Reads UART text files and extracts
the N field, then prints distinct values + counts for both.

Usage:
    python tools/analyze_v295.py V294_UART V295_UART
"""
from __future__ import annotations
import re
import sys
from collections import Counter
from pathlib import Path

N_RE = re.compile(r"\bN:([0-9A-Fa-f]{6})\b")
PC_RE = re.compile(r"\bPC:([0-9A-Fa-f]{6})\b")
I_RE = re.compile(r"\bI:([0-9A-Fa-f]{6})\b")

def field_dist(path: Path, regex: re.Pattern, name: str):
    if not path.exists():
        print(f"WARN: {path} missing, skipping")
        return
    txt = path.read_text(errors="ignore")
    vals = [m.group(1).upper() for m in regex.finditer(txt)]
    if not vals:
        print(f"  {name}: no matches in {path}")
        return
    c = Counter(vals)
    print(f"  {name}: {len(vals)} samples, {len(c)} distinct values")
    for v, n in c.most_common(10):
        print(f"    ${v} : {n} samples ({100 * n / len(vals):.1f}%)")

def main():
    if len(sys.argv) < 3:
        # Default: doom_full v294 vs (latest) v295 capture if present
        v294 = Path("tools/doom_full/uart_120s.txt")
        v295 = Path("tools/doom_full/uart_v295.txt")
        if not v295.exists():
            v295 = Path("tools/doom_full/uart_v295_120s.txt")
    else:
        v294 = Path(sys.argv[1])
        v295 = Path(sys.argv[2])
    print(f"v294 file: {v294}")
    print(f"v295 file: {v295}")

    print()
    print("=== N field (pc_main_r — main-thread last-fetch PC) ===")
    print(f"v294 ({v294}):")
    field_dist(v294, N_RE, "  N")
    print(f"v295 ({v295}):")
    field_dist(v295, N_RE, "  N")

    print()
    print("=== I field (pc_irq_r — IRQ-context last-fetch PC) ===")
    print(f"v294:")
    field_dist(v294, I_RE, "  I")
    print(f"v295:")
    field_dist(v295, I_RE, "  I")

    print()
    print("=== PC field (live cpu_pc at vblank) — sanity check ===")
    print(f"v294:")
    field_dist(v294, PC_RE, "  PC")
    print(f"v295:")
    field_dist(v295, PC_RE, "  PC")

if __name__ == "__main__":
    main()
