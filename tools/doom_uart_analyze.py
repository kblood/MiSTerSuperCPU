"""Analyze a Doom UART capture series.

For each uart_*.txt under a directory, extract:
- AC counter (final value)
- VW counter (final value)
- Set of distinct PC banks seen
- Set of distinct N (next-instr) bank-addr pairs
- Set of distinct WP (writer-PC) values
- VIC config tuples (D1, D8, C2) seen
- J ring values seen

Usage:
  python tools/doom_uart_analyze.py tools/doom_extended/
"""
import os, re, sys

LINE_RE = {
    'F':  re.compile(r'F:([0-9A-F]+)'),
    'PC': re.compile(r'PC:([0-9A-F]+)'),
    'N':  re.compile(r'N:([0-9A-F]+)'),
    'I':  re.compile(r'I:([0-9A-F]+)'),
    'B':  re.compile(r'B:([0-9A-F]+)'),
    'VW': re.compile(r'VW:([0-9A-F]+)'),
    'AC': re.compile(r'AC:([0-9A-F]+)'),
    'WP': re.compile(r'WP:([0-9A-F]+)'),
    'W5': re.compile(r'W5:([0-9A-F ]+?)\s+N5'),
    'J':  re.compile(r'J:([0-9A-F ]+?)\s+M:'),
    'M':  re.compile(r'M:([0-9A-F ]+?)\s+G:'),
    'D1': re.compile(r'D1:([0-9A-F]+)'),
    'D8': re.compile(r'D8:([0-9A-F]+)'),
    'C2': re.compile(r'C2:([0-9A-F]+)'),
    # 2026-05-09 doom-wait probe (commit 74e9c74) — last $00:$07xx read.
    # Field replaces VC. R7=AABB where AA = low byte of addr, BB = data byte.
    'R7': re.compile(r'R7:([0-9A-F]+)'),
}

def grab(line, key):
    m = LINE_RE[key].search(line)
    return m.group(1) if m else None

def analyze(path):
    last = {k: None for k in LINE_RE}
    pc_banks = set(); n_banks = set(); n_addrs = set(); wp_set = set()
    j_set = set(); m_set = set(); vic_tuples = set(); w5_set = set()
    r7_set = set()
    line_count = 0
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if 'PC:' not in line:
                continue
            line_count += 1
            for k in LINE_RE:
                v = grab(line, k)
                if v is not None:
                    last[k] = v
            pc = grab(line, 'PC')
            if pc and len(pc) >= 2: pc_banks.add(pc[:2])
            n  = grab(line, 'N')
            if n and len(n) >= 6: n_banks.add(n[:2]); n_addrs.add(n)
            wp = grab(line, 'WP')
            if wp: wp_set.add(wp)
            j  = grab(line, 'J')
            if j: j_set.add(j.strip())
            m  = grab(line, 'M')
            if m: m_set.add(m.strip())
            d1 = grab(line, 'D1'); d8 = grab(line, 'D8'); c2 = grab(line, 'C2')
            if d1 and d8 and c2: vic_tuples.add((d1, d8, c2))
            w5 = grab(line, 'W5')
            if w5: w5_set.add(w5.strip())
            r7 = grab(line, 'R7')
            if r7: r7_set.add(r7)
    return {
        'lines': line_count, 'last': last,
        'pc_banks': sorted(pc_banks), 'n_banks': sorted(n_banks),
        'n_addrs': sorted(n_addrs), 'wp_set': sorted(wp_set),
        'j_set': sorted(j_set), 'm_set': sorted(m_set),
        'vic_tuples': sorted(vic_tuples), 'w5_set': sorted(w5_set),
        'r7_set': sorted(r7_set),
    }

def main():
    if len(sys.argv) < 2:
        print('usage: doom_uart_analyze.py <dir>'); sys.exit(1)
    d = sys.argv[1]
    files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.startswith('uart_') and f.endswith('.txt'))
    if not files:
        print(f'no uart_*.txt in {d}'); sys.exit(1)
    for path in files:
        print(f'=== {os.path.basename(path)} ===')
        r = analyze(path)
        L = r['last']
        print(f'  lines: {r["lines"]}')
        print(f'  last: F={L["F"]} PC={L["PC"]} N={L["N"]} I={L["I"]} B={L["B"]} VW={L["VW"]} AC={L["AC"]}')
        print(f'        WP={L["WP"]} J=[{L["J"]}] M=[{L["M"]}] W5=[{L["W5"]}]')
        print(f'        VIC: D1={L["D1"]} D8={L["D8"]} C2={L["C2"]}')
        print(f'  PC banks seen: {r["pc_banks"]}')
        print(f'  N banks seen: {r["n_banks"]}  ({len(r["n_addrs"])} distinct N addrs)')
        print(f'  WP set ({len(r["wp_set"])}): {r["wp_set"][:8]}{"..." if len(r["wp_set"])>8 else ""}')
        print(f'  J ring set ({len(r["j_set"])}): {r["j_set"][:4]}{"..." if len(r["j_set"])>4 else ""}')
        print(f'  M ring set ({len(r["m_set"])}): {r["m_set"][:4]}{"..." if len(r["m_set"])>4 else ""}')
        print(f'  W5 ring set ({len(r["w5_set"])}): {r["w5_set"][:6]}{"..." if len(r["w5_set"])>6 else ""}')
        print(f'  VIC tuples ({len(r["vic_tuples"])}): {r["vic_tuples"]}')
        # 2026-05-09 doom-wait probe — shows distinct $00:$07xx reads.
        # Locked = wait condition pinned. Cycling = inner loop has structure.
        if r.get('r7_set'):
            print(f'  R7 distinct ({len(r["r7_set"])}): {r["r7_set"][:8]}{"..." if len(r["r7_set"])>8 else ""}')
        print()

    # AC growth summary
    print('=== AC growth ===')
    ac_pts = []
    for path in files:
        r = analyze(path)
        ac = r['last'].get('AC')
        try:
            t = int(os.path.basename(path).split('_')[1].rstrip('s.txt'))
        except (IndexError, ValueError):
            t = -1
        if ac:
            ac_pts.append((t, int(ac, 16)))
    for t, v in ac_pts:
        print(f'  t={t:>4}s  AC=0x{v:04X} = {v}')
    if len(ac_pts) >= 2:
        for i in range(1, len(ac_pts)):
            t0,v0 = ac_pts[i-1]; t1,v1 = ac_pts[i]
            if t1 > t0:
                print(f'  delta {t0}s->{t1}s: {v1-v0} ticks ({(v1-v0)/(t1-t0):.1f}/sec)')

if __name__ == '__main__':
    main()
