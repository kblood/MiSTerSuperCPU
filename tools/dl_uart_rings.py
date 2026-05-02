#!/usr/bin/env python3
"""Analyze v2/v3/v4 JSR + JMP-indirect rings + DL gate variables.

v2 line format (114 bytes):
  F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:#### J:#### #### #### #### M:#### #### #### ####
v3 adds " G:## ## ##" (gate variables $40/$44/$5C) -> 125 bytes.
v4 adds " N:###### I:###### B:## C3:#### C9:####" -> 164 bytes.
  N  = main-thread PC (last opcode fetch with I-flag clear)
  I  = IRQ-thread PC  (last opcode fetch with I-flag set)
  B  = wait-loop variable $0045
  C3 = opcode-fetch count for page $30 (FLI body)
  C9 = opcode-fetch count for page $97 (SCPU divergent ROM region)

Reports:
  - Top JSR PCs (4 per frame ring -> 4000 entries / 1000 frames)
  - Top JMP-indirect targets (M: ring)
  - JSR page distribution per mode
  - First-N frame J/M side-by-side
  - (v3) Gate variable distributions and per-frame bands
  - (v4) Main-thread PC distribution, IRQ-thread PC, $45 dynamics, C3/C9 deltas
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
    r"(?:\s+N:(?P<n>[0-9A-F]+)\s+I:(?P<ii>[0-9A-F]+)\s+B:(?P<b>[0-9A-F]+)(?:\s+C3:(?P<c3>[0-9A-F]+)\s+C9:(?P<c9>[0-9A-F]+))?(?:\s+SP:(?P<sp0x>[0-9A-F]+)\s+(?P<sp0y>[0-9A-F]+)\s+(?P<sp1x>[0-9A-F]+)\s+(?P<sp1y>[0-9A-F]+))?)?"
    r"(?:\s+W5:(?P<w5c0>[0-9A-F]+)\s+(?P<w5c1>[0-9A-F]+)\s+(?P<w5c2>[0-9A-F]+)\s+(?P<w5c3>[0-9A-F]+)\s+N5:(?P<n5>[0-9A-F]+))?"
    r"(?:\s+IF:(?P<irf>[0-9A-F]+)\s+VC:(?P<ivc>[0-9A-F]+)\s+DR:(?P<dr>[0-9A-F]+)\s+DS:(?P<ds>[0-9A-F]+))?"
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
        if m['n'] is not None:
            row['n']  = int(m['n'],  16)
            row['ii'] = int(m['ii'], 16)
            row['b']  = int(m['b'],  16)
            if m['c3'] is not None:
                row['c3'] = int(m['c3'], 16)
                row['c9'] = int(m['c9'], 16)
            if m['sp0x'] is not None:
                row['sp0x'] = int(m['sp0x'], 16)
                row['sp0y'] = int(m['sp0y'], 16)
                row['sp1x'] = int(m['sp1x'], 16)
                row['sp1y'] = int(m['sp1y'], 16)
        if m['w5c0'] is not None:
            row['w5c'] = [int(m[f'w5c{i}'], 16) for i in range(4)]
            row['n5']  = int(m['n5'], 16)
        if m['irf'] is not None:
            row['irf'] = int(m['irf'], 16)
            row['ivc'] = int(m['ivc'], 16)
            row['dr']  = int(m['dr'],  16)
            row['ds']  = int(m['ds'],  16)
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

    if rows and 'n' in rows[0]:
        print('  v4 main/IRQ PC + page counters:')
        n_pages = collections.Counter((r['n']  >> 8) & 0xFF for r in rows)
        i_pages = collections.Counter((r['ii'] >> 8) & 0xFF for r in rows)
        b_dist  = collections.Counter(r['b']  for r in rows)
        n_top   = collections.Counter(r['n']  for r in rows).most_common(10)
        i_top   = collections.Counter(r['ii'] for r in rows).most_common(10)
        print('    main-thread PC top-10 (sampled at vblank):')
        for pc, c in n_top:
            print(f'      {pc:06X}  {c:5d}  ({100*c/len(rows):5.1f}%)')
        print('    main-thread PC page distribution (top 8):')
        for p, c in sorted(n_pages.items(), key=lambda kv: -kv[1])[:8]:
            print(f'      page ${p:02X}  {100*c/len(rows):5.1f}%')
        print('    IRQ-thread PC top-10 (sampled at vblank):')
        for pc, c in i_top:
            print(f'      {pc:06X}  {c:5d}  ({100*c/len(rows):5.1f}%)')
        print(f'    $0045 (wait-loop var): top values: {[(hex(v), c) for v, c in b_dist.most_common(5)]}')
        # C3/C9 deltas: monotonic counters, take last - first to get total over capture
        if len(rows) > 1 and 'c3' in rows[0]:
            d3 = (rows[-1]['c3'] - rows[0]['c3']) & 0xFFFF
            d9 = (rows[-1]['c9'] - rows[0]['c9']) & 0xFFFF
            print(f'    C3 delta (page $30 opcode fetches): {d3} over {len(rows)} frames ({d3/len(rows):.1f}/frame)')
            print(f'    C9 delta (page $97 opcode fetches): {d9} over {len(rows)} frames ({d9/len(rows):.1f}/frame)')

    # v264: sprite-position last-write values
    sp_rows = [r for r in rows if 'sp0x' in r]
    if sp_rows:
        print('  v264 sprite positions ($D000=spr0_x, $D001=spr0_y, $D002=spr1_x, $D003=spr1_y):')
        for key, label in [('sp0x','spr0_x'),('sp0y','spr0_y'),('sp1x','spr1_x'),('sp1y','spr1_y')]:
            dist = collections.Counter(r[key] for r in sp_rows)
            top = [(f'${v:02X}', c) for v, c in dist.most_common(8)]
            uniq = len(dist)
            print(f'    {label} unique:{uniq:3d}  top: {top}')
        # First-12 frames sprite snapshot
        print('    first 12 frames spr0_x spr0_y / spr1_x spr1_y:')
        for i, r in enumerate(sp_rows[:12]):
            print(f'      {i:>3}  {r["sp0x"]:02X} {r["sp0y"]:02X}  /  {r["sp1x"]:02X} {r["sp1y"]:02X}')

    if rows and 'w5c' in rows[0]:
        print('  v262 $005C write-ring (4-deep, oldest..newest) + writes/frame:')
        # Per-position distributions across all rows
        for pos in range(4):
            dist = collections.Counter(r['w5c'][pos] for r in rows)
            top = [(f'${v:02X}', c) for v, c in dist.most_common(5)]
            print(f'    pos[{pos}] top: {top}')
        # Aggregate "what values ever appear in the ring"
        all_vals = [v for r in rows for v in r['w5c']]
        all_dist = collections.Counter(all_vals).most_common(8)
        print(f'    all-positions distribution (top 8): {[(f"${v:02X}", c) for v,c in all_dist]}')
        # Writes-per-frame from N5 deltas
        if len(rows) > 1:
            dn5 = (rows[-1]['n5'] - rows[0]['n5']) & 0xFFFF
            print(f'    N5 delta (writes to $005C): {dn5} over {len(rows)} frames ({dn5/len(rows):.2f}/frame)')
        # First-12 raw rings to read the cycle directly
        print('    first 12 frames raw rings:')
        for i, r in enumerate(rows[:12]):
            print(f'      {i:>3}  {" ".join(f"{v:02X}" for v in r["w5c"])}  N5:{r["n5"]:04X}')

    irf_rows = [r for r in rows if 'irf' in r]
    if irf_rows:
        print('  v263 IRQ-source counters + $D019 read-side:')
        if len(irf_rows) > 1:
            dif = (irf_rows[-1]['irf'] - irf_rows[0]['irf']) & 0xFFFF
            div = (irf_rows[-1]['ivc'] - irf_rows[0]['ivc']) & 0xFFFF
            print(f'    IF delta (IRQ_N falling edges):     {dif:6d} over {len(irf_rows)} frames ({dif/len(irf_rows):.2f}/frame)')
            print(f'    VC delta ($FFFE/$FFFF vec fetches): {div:6d} over {len(irf_rows)} frames ({div/len(irf_rows):.2f}/frame)')
            print(f'    VC/IF ratio: {div/max(dif,1):.2f}  (>2.0 means tail-chain on same source pulse; ~1.0 = 1 vec per pulse; ~2.0 = each entry fetches 2 bytes)')
        dr_dist = collections.Counter(r['dr'] for r in irf_rows)
        ds_or   = 0
        for r in irf_rows: ds_or |= r['ds']
        print(f'    DR ($D019 last-read) top 5: {[(f"${v:02X}", c) for v, c in dr_dist.most_common(5)]}')
        print(f'    DS (cumulative seen-bits 0..3) sticky-OR across capture: ${ds_or:X}')
        # Decode DR bit meaning
        for v, c in dr_dist.most_common(3):
            bits = []
            if v & 0x01: bits.append('IRST')
            if v & 0x02: bits.append('IMBC')
            if v & 0x04: bits.append('IMMC')
            if v & 0x08: bits.append('ILP')
            print(f'      ${v:02X} = {"+".join(bits) if bits else "(no source bits)"}  (top bit is IRQ-pending flag)')


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
