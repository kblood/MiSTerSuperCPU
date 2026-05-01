#!/usr/bin/env python3
"""Analyze a pair of DBG_UART traces from dl_uart_capture.py and surface
the time-correlated divergences between T65 and SCPU runs.

The traces are time-aligned (each captured 20s after PRG-load fired) so
the same wall-clock interval of DL animation is sampled in both modes.
PC is sampled at vblank rising edge — one sample per frame at PAL 50 Hz.

Reports:
  - Per-mode unique-PC count + top-N PC histogram (high byte / page)
  - Per-mode CY/CG growth rate
  - V-ring distribution
  - First-N frame PC sequence side by side
"""
import sys, collections, os

def load(path):
    rows = []
    for line in open(path):
        toks = line.strip().split()
        if not toks or len(toks) < 8:
            continue
        try:
            f  = int(toks[0].split(':')[1], 16)
            pc = int(toks[1].split(':')[1], 16)
            p  = int(toks[2].split(':')[1], 16)
            v0 = int(toks[3].split(':')[1], 16)
            v1 = int(toks[4], 16)
            v2 = int(toks[5], 16)
            v3 = int(toks[6], 16)
            yx = toks[7].split(':')[1]
            wp = int(toks[8].split(':')[1], 16)
            cg = int(toks[9].split(':')[1], 16)
            cy = int(toks[10].split(':')[1], 16)
        except Exception:
            continue
        rows.append((f, pc, p, [v0, v1, v2, v3], yx, wp, cg, cy))
    return rows

def histogram(rows, top=20):
    h = collections.Counter(r[1] for r in rows)
    return h.most_common(top)

def page_histogram(rows):
    h = collections.Counter((r[1] >> 8) & 0xFFFF for r in rows)
    return sorted(h.items(), key=lambda kv: -kv[1])

def main():
    if len(sys.argv) < 3:
        print('Usage: dl_uart_diff.py <t65.txt> <scpu.txt>')
        sys.exit(1)
    t65_path, scpu_path = sys.argv[1], sys.argv[2]
    t = load(t65_path)
    s = load(scpu_path)
    print(f'T65 : {len(t)} samples  PCs:{len(set(r[1] for r in t))}')
    print(f'SCPU: {len(s)} samples  PCs:{len(set(r[1] for r in s))}')

    print('\n== PC top-15 histogram (frame samples at vblank) ==')
    print(f'{"T65":<22} {"SCPU":<22}')
    th = histogram(t, 15); sh = histogram(s, 15)
    for i in range(max(len(th), len(sh))):
        tcell = f'{th[i][0]:06X} : {th[i][1]:4d}' if i < len(th) else ''
        scell = f'{sh[i][0]:06X} : {sh[i][1]:4d}' if i < len(sh) else ''
        print(f'  {tcell:<20}   {scell}')

    print('\n== PC by high-byte (page) — % of frames ==')
    tn = sum(1 for _ in t); sn = sum(1 for _ in s)
    th = page_histogram(t); sh = page_histogram(s)
    pages = sorted(set([p for p,_ in th] + [p for p,_ in sh]))
    print(f'  page    T65 %    SCPU %')
    for p in pages:
        tc = next((c for pp,c in th if pp == p), 0)
        sc = next((c for pp,c in sh if pp == p), 0)
        print(f'  {p:04X}  {100*tc/tn:6.2f}   {100*sc/sn:6.2f}')

    if t and s:
        print('\n== Time-aligned first 12 frames side by side ==')
        print(f'  {"#":>3}  {"T65 PC":<8}  {"SCPU PC":<8}')
        for i in range(min(12, len(t), len(s))):
            print(f'  {i:>3}  {t[i][1]:06X}    {s[i][1]:06X}')

    print('\n== CG / CY rates ==')
    if t:
        dcy_t = t[-1][7] - t[0][7]; dcg_t = t[-1][6] - t[0][6]; df_t = t[-1][0] - t[0][0]
        print(f'  T65 : df={df_t}  dCY={dcy_t}  dCG={dcg_t}  (CG/CY={dcg_t/dcy_t if dcy_t else 0:.3f})')
    if s:
        dcy_s = s[-1][7] - s[0][7]; dcg_s = s[-1][6] - s[0][6]; df_s = s[-1][0] - s[0][0]
        print(f'  SCPU: df={df_s}  dCY={dcy_s}  dCG={dcg_s}  (CG/CY={dcg_s/dcy_s if dcy_s else 0:.3f})')
        if t and dcy_t:
            print(f'  SCPU CY rate / T65 CY rate = {dcy_s/dcy_t:.3f}')

    print('\n== V ring distribution (frame-samples by V0:V1:V2:V3) ==')
    tvc = collections.Counter(tuple(r[3]) for r in t)
    svc = collections.Counter(tuple(r[3]) for r in s)
    vs = sorted(set(tvc) | set(svc))
    for v in vs:
        sig = ' '.join(f'{x:02X}' for x in v)
        tc = tvc.get(v, 0); sc = svc.get(v, 0)
        print(f'  {sig}   T65:{tc:5d}  SCPU:{sc:5d}')

if __name__ == '__main__':
    main()
