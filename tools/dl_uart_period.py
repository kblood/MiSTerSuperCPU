#!/usr/bin/env python3
"""Look for periodicity / phase / state-cycle in the per-frame PC trace.

Run on a single trace:
  python tools/dl_uart_period.py <trace.txt>

Prints:
  - Auto-correlation peaks (period detection)
  - PC sequence as compact "page tokens" for visual pattern check
"""
import sys, collections

def load(path):
    rows = []
    for line in open(path):
        toks = line.strip().split()
        if not toks or len(toks) < 2:
            continue
        try:
            f  = int(toks[0].split(':')[1], 16)
            pc = int(toks[1].split(':')[1], 16)
        except Exception:
            continue
        rows.append((f, pc))
    return rows

def page_token(pc):
    """Map PC to a single character based on page byte."""
    p = (pc >> 8) & 0xFF
    if p == 0x30: return '3'
    if p == 0x80: return '0'
    if p == 0x83: return 'i'
    if p == 0x85: return '5'
    if p == 0x89: return '9'
    if p == 0x97: return 'r'   # ROM 97
    if p == 0x98: return 'R'   # ROM 98
    if p == 0x96: return 's'
    if p == 0x99: return 'S'
    if p == 0x17: return 'a'   # RAM 17
    if p == 0x18: return 'b'
    return '.'

def auto_corr(seq, max_lag=20):
    n = len(seq)
    out = []
    for lag in range(1, max_lag+1):
        match = sum(1 for i in range(n - lag) if seq[i] == seq[i + lag])
        out.append((lag, match / (n - lag)))
    return out

def main():
    path = sys.argv[1]
    rows = load(path)
    pcs = [pc for _, pc in rows]
    pages = [page_token(pc) for pc in pcs]
    print(f'Trace: {path}')
    print(f'Frames: {len(rows)}  unique PCs: {len(set(pcs))}')
    print()
    print('Page-token sequence (first 200 frames):')
    s = ''.join(pages[:200])
    for i in range(0, len(s), 50):
        print(f'  [{i:4d}] {s[i:i+50]}')
    print()
    print('Auto-correlation by lag:')
    for lag, r in auto_corr(pcs, max_lag=20):
        bar = '#' * int(r * 60)
        print(f'  lag {lag:2d}: {r:5.3f} {bar}')

    print()
    print('PC histogram (top 25):')
    h = collections.Counter(pcs).most_common(25)
    for pc, c in h:
        print(f'  {pc:06X}  {c:5d}  ({100*c/len(pcs):5.1f}%)')

if __name__ == '__main__':
    main()
