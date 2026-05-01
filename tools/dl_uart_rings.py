#!/usr/bin/env python3
"""Analyze v2/v3 JSR + JMP-indirect rings + (v3) DL gate variables.

v2 line format (114 bytes):
  F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### ####
v3 adds " G:## ## ##" (gate variables $40/$44/$5C) -> 125 bytes.

Reports:
  - Top JSR PCs (4 per frame ring -> 4000 entries / 1000 frames)
  - Top JMP-indirect targets (M: ring)
  - JSR page distribution per mode
  - First-N frame J/M side-by-side
  - (v3) Gate variable distributions and per-frame bands
"""
import sys, re, collections

LINE_RE = re.compile(
    r"F:(?P<f>[0-9A-F]+)\s+"
    r"PC:(?P<pc>[0-9A-F]+)\s+"
    r"P:(?P<p>[0-9A-F]+)\s+"
    r"V:(?P<v0>[0-9A-F]+)\s+(?P<v1>[0-9A-F]+)\s+(?P<v2>[0-9A-F]+)\s+(?P<v3>[0-9A-F]+)\s+"
    r"YX:(?P<yx>[0-9A-F]+)\s+"
    r"WP:(?P<wp>[0-9A-F]+)\s+"
    r"CG:(?P<cg>[0-9A-F]+)\s+"
    r"CY:(?P<cy>[0-9A-F]+)\s+"
    r"J:(?P<j0>[0-9A-F]+)\s+(?P<j1>[0-9A-F]+)\s+(?P<j2>[0-9A-F]+)\s+(?P<j3>[0-9A-F]+)\s+"
    r"M:(?P<m0>[0-9A-F]+)\s+(?P<m1>[0-9A-F]+)\s+(?P<m2>[0-9A-F]+)\s+(?P<m3>[0-9A-F]+)"
    r"(?:\s+G:(?P<g40>[0-9A-F]+)\s+(?P<g44>[0-9A-F]+)\s+(?P<g5c>[0-9A-F]+))?"
)


def load(path):
    rows = []
    for line in open(path):
        m = LINE_RE.search(line)
        if not m:
            continue
        row = {
            'f': int(m['f'], 16), 'pc': int(m['pc'], 16),
            'j': [int(m[f'j{i}'], 16) for i in range(4)],
            'm': [int(m[f'm{i}'], 16) for i in range(4)],
        }
        if m['g40'] is not None:
            row['g40'] = int(m['g40'], 16)
            row['g44'] = int(m['g44'], 16)
            row['g5c'] = int(m['g5c'], 16)
        rows.append(row)
    return rows


def report(rows, label):
    print(f'\n== {label}  frames:{len(rows)} ==')
    j_all = [j for r in rows for j in r['j']]
    m_all = [mm for r in rows for mm in r['m']]
    j_pages = collections.Counter((j >> 8) & 0xFF for j in j_all)
    m_pages = collections.Counter((mm >> 8) & 0xFF for mm in m_all)
    j_top = collections.Counter(j_all).most_common(15)
    m_top = collections.Counter(m_all).most_common(15)

    print('  JSR top-15 (4× per frame):')
    for pc, c in j_top:
        print(f'    {pc:04X}  {c:5d}  ({100*c/len(j_all):5.1f}%)')
    print('  JSR page distribution (top 10):')
    for p, c in sorted(j_pages.items(), key=lambda kv: -kv[1])[:10]:
        print(f'    page ${p:02X}  {100*c/len(j_all):5.1f}%')

    print('  JMP-ind target top-15 (4× per frame):')
    for pc, c in m_top:
        print(f'    {pc:04X}  {c:5d}  ({100*c/len(m_all):5.1f}%)')
    print('  JMP-ind page distribution (top 10):')
    for p, c in sorted(m_pages.items(), key=lambda kv: -kv[1])[:10]:
        print(f'    page ${p:02X}  {100*c/len(m_all):5.1f}%')

    if rows and 'g40' in rows[0]:
        print('  Gate variables ($40 BNE-zero gate / $44 BEQ-zero gate / $5C IRQ counter):')
        g40 = collections.Counter(r['g40'] for r in rows)
        g44 = collections.Counter(r['g44'] for r in rows)
        g5c = collections.Counter(r['g5c'] for r in rows)
        print(f'    $40 zero rate: {100*g40.get(0,0)/len(rows):5.1f}%   top vals: {[hex(v) for v,_ in g40.most_common(5)]}')
        print(f'    $44 zero rate: {100*g44.get(0,0)/len(rows):5.1f}%   top vals: {[hex(v) for v,_ in g44.most_common(5)]}')
        print(f'    $5C zero rate: {100*g5c.get(0,0)/len(rows):5.1f}%   top vals: {[hex(v) for v,_ in g5c.most_common(5)]}')
        # Gate predicate: game advance fires iff $44 == 0 AND $40 != 0
        n_advance = sum(1 for r in rows if r['g44'] == 0 and r['g40'] != 0)
        print(f'    GAME-ADVANCE-LIKELY frames ($44==0 AND $40!=0): {100*n_advance/len(rows):5.1f}%')


def main():
    if len(sys.argv) < 3:
        print('Usage: dl_uart_rings.py <t65.txt> <scpu.txt>')
        sys.exit(1)
    t = load(sys.argv[1])
    s = load(sys.argv[2])
    report(t, 'T65')
    report(s, 'SCPU')

    print('\n== Time-aligned first-12 frames J/M side by side ==')
    print(f'  {"#":>3}  {"T65 J ring":<24}  {"T65 M ring":<24}  | {"SCPU J ring":<24}  {"SCPU M ring":<24}')
    for i in range(min(12, len(t), len(s))):
        tj = ' '.join(f'{x:04X}' for x in t[i]['j'])
        tm = ' '.join(f'{x:04X}' for x in t[i]['m'])
        sj = ' '.join(f'{x:04X}' for x in s[i]['j'])
        sm = ' '.join(f'{x:04X}' for x in s[i]['m'])
        print(f'  {i:>3}  {tj:<24}  {tm:<24}  | {sj:<24}  {sm:<24}')


if __name__ == '__main__':
    main()
