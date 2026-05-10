#!/usr/bin/env python3
"""
v245 analysis: decode T65/SCPU screenshots, disassemble bytes around the
$335F divergent writer, $3300 dispatcher entry, $3100 chain handler.
Compare actual VALUES written to $0070/$0071 (cpuDo) between modes.

Layout (rows):
  R4  3380 [8 bytes]                  - drift sentinel (v244 KEEP)
  R5  V0=## V1=## W=######            - v245 written values + writer PC
  R6  9F09 [8 bytes]                  - FLI sentinel (v244 KEEP)
  R7  9F11 [8 bytes]                  - FLI sentinel (v244 KEEP)
  R8  5D:[16 hex chars = 8 bytes $335D-$3364]
  R9  65:[16 hex chars = 8 bytes $3365-$336C]
  R10 30:[16 hex chars = 8 bytes $3300-$3307]
  R11 10:[16 hex chars = 8 bytes $3100-$3107]

Usage:
  python tools/analyze_v245.py
"""
import os, sys, subprocess, glob

# Reuse v244 disassembler
from analyze_v244 import OPS, disasm, parse_overlay, parse_pc

def hex_after_colon(s):
    """Parse '5D:0102030405060708090A0B0C0D0E0F10' → list of bytes.

    Row format is `<label-with-colon><hex chars>`. Split on first ':' or
    first non-hex char run; take the trailing hex string.
    """
    if not s:
        return []
    # Strip optional label up to ':'
    if ':' in s:
        s = s.split(':', 1)[1]
    s = s.replace(' ', '').replace('=', '').strip()
    # Take leading hex run only
    out = []
    for i in range(0, len(s) - 1, 2):
        try:
            out.append(int(s[i:i+2], 16))
        except ValueError:
            break
    return out

def parse_v245_row5(s):
    """Row 5 = 'V0=XX V1=YY W=ZZZZZZ' — extract dict."""
    d = {}
    s = s.replace(' ', '')
    # V0=XX
    if 'V0=' in s:
        i = s.index('V0=') + 3
        d['V0'] = s[i:i+2]
    if 'V1=' in s:
        i = s.index('V1=') + 3
        d['V1'] = s[i:i+2]
    if 'W=' in s:
        i = s.index('W=') + 2
        d['W'] = s[i:i+6]
    return d

def analyze_dir(d, label):
    print(f'\n========== {label}: {d} ==========')
    pngs = sorted(glob.glob(os.path.join(d, '*.png')))
    if not pngs:
        print('  (no captures)')
        return
    seen_335D = set()
    seen_3300 = set()
    seen_3100 = set()
    seen_3380 = set()
    seen_9F09 = set()
    seen_v5   = set()
    last_rows = None
    for p in pngs:
        rows = parse_overlay(p)
        last_rows = rows
        # v245 byte ranges
        b_335D = tuple(hex_after_colon(rows.get('R8', ''))[:8] +
                       hex_after_colon(rows.get('R9', ''))[:8])
        b_3300 = tuple(hex_after_colon(rows.get('R10', ''))[:8])
        b_3100 = tuple(hex_after_colon(rows.get('R11', ''))[:8])
        # v244 sentinels (only first 8 bytes — row 5 is now V0/V1)
        # Row 4 is '3380 ## ## ## ## ## ## ## ##' format with spaces;
        # hex_to_bytes from v244 strips first token then concatenates.
        from analyze_v244 import hex_to_bytes
        b_3380 = tuple(hex_to_bytes(rows.get('R4', ''))[:8])
        b_9F09 = tuple(hex_to_bytes(rows.get('R6', ''))[:8] +
                       hex_to_bytes(rows.get('R7', ''))[:8])
        if len(b_335D) >= 16: seen_335D.add(b_335D)
        if len(b_3300) >= 8:  seen_3300.add(b_3300)
        if len(b_3100) >= 8:  seen_3100.add(b_3100)
        if len(b_3380) >= 8:  seen_3380.add(b_3380)
        if len(b_9F09) >= 16: seen_9F09.add(b_9F09)
        seen_v5.add(rows.get('R5', ''))

    print(f'\n  --- Row 5 (write values + writer PC) ---')
    for s in sorted(seen_v5):
        print(f'    {s}  → {parse_v245_row5(s)}')

    if seen_335D:
        print(f'\n  --- $335D..$336C (writer + context) [{len(seen_335D)} pattern{"s" if len(seen_335D)!=1 else ""}] ---')
        for b in sorted(seen_335D):
            print('   ', ' '.join(f'{x:02X}' for x in b))
        print(f'\n  Disassembly (first observed):')
        b = list(next(iter(sorted(seen_335D))))
        for line in disasm(b, 0x335D):
            print(line)

    if seen_3300:
        print(f'\n  --- $3300..$3307 (alt dispatcher) [{len(seen_3300)} pattern{"s" if len(seen_3300)!=1 else ""}] ---')
        for b in sorted(seen_3300):
            print('   ', ' '.join(f'{x:02X}' for x in b))
        print(f'\n  Disassembly (first observed):')
        b = list(next(iter(sorted(seen_3300))))
        for line in disasm(b, 0x3300):
            print(line)

    if seen_3100:
        print(f'\n  --- $3100..$3107 (chain handler) [{len(seen_3100)} pattern{"s" if len(seen_3100)!=1 else ""}] ---')
        for b in sorted(seen_3100):
            print('   ', ' '.join(f'{x:02X}' for x in b))
        print(f'\n  Disassembly (first observed):')
        b = list(next(iter(sorted(seen_3100))))
        for line in disasm(b, 0x3100):
            print(line)

    if seen_3380:
        print(f'\n  --- $3380..$3387 (drift sentinel — should match v244) ---')
        for b in sorted(seen_3380):
            print('   ', ' '.join(f'{x:02X}' for x in b))

    if seen_9F09:
        print(f'\n  --- $9F09..$9F18 (FLI drift sentinel — should match v244) ---')
        for b in sorted(seen_9F09):
            print('   ', ' '.join(f'{x:02X}' for x in b))

if __name__ == '__main__':
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(base)
    analyze_dir('tools/dl_screens_v245_t65', 'T65')
    analyze_dir('tools/dl_screens_v245_scpu', 'SCPU')
