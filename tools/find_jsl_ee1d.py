"""Search doom.reu for `JSL ?:$EE1D` opcode patterns.

JSL = $22, operand = 3 bytes little-endian (PCL, PCH, PB).
We're looking for a JSL whose target lower 16 bits = $EE1D — that means
operand bytes [22 1D EE bb] where bb is the target bank.

Hypothesis from UART (2026-05-09): pc_main is in bank $FC executing BRKs;
J ring shows ...EE1D × 4 → Doom JSLs to $FC:$EE1D and lands in SDRAM zeros.
This script confirms the bank by listing every `22 1D EE bb` site in REU.

Usage: python tools/find_jsl_ee1d.py [path/to/doom.reu]
"""
import sys, struct

REU = sys.argv[1] if len(sys.argv) > 1 else 'doom.reu'
BANK_SIZE = 0x10000

with open(REU, 'rb') as f:
    data = f.read()

print(f'{REU}: {len(data):,} bytes ({len(data)//BANK_SIZE} banks)')
print()

hits_by_target = {}
for i in range(len(data) - 3):
    if data[i] == 0x22 and data[i+1] == 0x1D and data[i+2] == 0xEE:
        target_bank = data[i+3]
        # Map REU offset to (bank, addr): REU is loaded into REU SDRAM,
        # then Doom long-stores it into SuperRAM banks. The byte at
        # REU offset N is at REU bank (N >> 16), REU addr (N & 0xFFFF).
        reu_bank = i // BANK_SIZE
        reu_addr = i % BANK_SIZE
        key = target_bank
        hits_by_target.setdefault(key, []).append((reu_bank, reu_addr))

print(f'Total `22 1D EE bb` matches: {sum(len(v) for v in hits_by_target.values())}')
print()
print('By target bank (the bb byte after 22 1D EE):')
for tb in sorted(hits_by_target.keys()):
    sites = hits_by_target[tb]
    print(f'  target ${tb:02X}:$EE1D  -- {len(sites)} site(s)')
    for (rb, ra) in sites[:5]:
        print(f'    REU bank ${rb:02X} offset ${ra:04X}')
    if len(sites) > 5:
        print(f'    ... +{len(sites)-5} more')
