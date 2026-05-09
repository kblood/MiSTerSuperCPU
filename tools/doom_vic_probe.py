"""Extract D1/D8/C2 (VIC bank-select) values from a captured UART trace.

Reads a doom_full/uart_*.txt file and reports:
  - Last seen $D011, $D018, $DD00 values
  - VIC bank (CIA2 PRA bits 1-0 inverted; bank 0..3 = $0000/$4000/$8000/$C000)
  - Bitmap mode active? (D011 bit 5)
  - Screen RAM base + bitmap base offsets within VIC bank from D018

Usage: python tools/doom_vic_probe.py <uart.txt>
"""
import re, sys

LINE_RE = re.compile(r'D1:([0-9A-F]{2}) D8:([0-9A-F]{2}) C2:([0-9A-F]{2})')

def main():
    if len(sys.argv) < 2:
        print('usage: doom_vic_probe.py <uart.txt>'); sys.exit(1)
    path = sys.argv[1]
    last = None
    counts = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = LINE_RE.search(line)
            if m:
                key = (m.group(1), m.group(2), m.group(3))
                counts[key] = counts.get(key, 0) + 1
                last = key
    if not last:
        print(f'no D1/D8/C2 fields in {path}'); sys.exit(1)
    d011 = int(last[0], 16); d018 = int(last[1], 16); dd00 = int(last[2], 16)
    print(f'last D1:{last[0]} D8:{last[1]} C2:{last[2]}')
    bmm   = (d011 >> 5) & 1
    den   = (d011 >> 4) & 1
    ecm   = (d011 >> 6) & 1
    rsel  = (d011 >> 3) & 1
    yscl  = d011 & 7
    bank_n = (~dd00) & 3
    bank_b = bank_n * 0x4000
    scr_off = ((d018 >> 4) & 0xF) * 0x0400
    bm_off  = ((d018 >> 3) & 1) * 0x2000
    chr_off = ((d018 >> 1) & 7) * 0x0800
    print(f'  D011: BMM={bmm} ECM={ecm} DEN={den} RSEL={rsel} YSCROLL={yscl}')
    print(f'  D018: screen_off=${scr_off:04X}  bitmap_off=${bm_off:04X}  chr_off=${chr_off:04X}')
    print(f'  C2:   VIC bank {bank_n} = ${bank_b:04X}-${bank_b+0x3FFF:04X}')
    print(f'  -> screen RAM at  ${bank_b+scr_off:04X}')
    if bmm:
        print(f'  -> bitmap   RAM at ${bank_b+bm_off:04X} (8000 bytes)')
        print('  -> mode = BITMAP')
    else:
        print(f'  -> char ROM at    ${bank_b+chr_off:04X}')
        print('  -> mode = TEXT')
    print()
    print('Distinct (D1,D8,C2) tuples seen:')
    for k, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f'  {k}  x{n}')

if __name__ == '__main__':
    main()
