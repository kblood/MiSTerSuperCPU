#!/usr/bin/env python3
"""Analyze v2 JSR + JMP-indirect rings from dl_uart_capture v2 traces.

v2 line format (114 bytes):
  F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### ####

Reports:
  - Top JSR PCs (4 per frame ring -> 4000 entries / 1000 frames)
  - Top JMP-indirect targets (M: ring)
  - JSR page distribution per mode
  - First-N frame J/M side-by-side
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
)


def load(path):
    rows = []
    for line in open(path):
        m = LINE_RE.search(line)
        if not m:
            continue
        rows.append({
            'f': int(m['f'], 16), 'pc': int(m['pc'], 16),
            'j': [int(m[f'j{i}'], 16) for i in range(4)],
            'm': [int(m[f'm{i}'], 16) for i in range(4)],
        })
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
