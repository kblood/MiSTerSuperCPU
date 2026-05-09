"""Find every byte sequence in doom.reu that targets address $EE1D, and
also examine what's AT $EE1D in each REU bank.

Patterns:
  $20 1D EE         JSR $EE1D (intra-bank)
  $22 1D EE bb      JSL $bb:$EE1D (long)
  $4C 1D EE         JMP $EE1D
  $5C 1D EE bb      JML $bb:$EE1D

Plus, dump the first 16 bytes at offset $EE1D in each REU bank to see what
landing pad looks like across banks (most banks contain $00, but some may
have actual code).
"""
import sys

REU = sys.argv[1] if len(sys.argv) > 1 else 'doom.reu'
BANK_SIZE = 0x10000
TARGET_LO, TARGET_HI = 0x1D, 0xEE

with open(REU, 'rb') as f:
    data = f.read()

print(f'{REU}: {len(data):,} bytes ({len(data)//BANK_SIZE} banks)')
print()

# Pattern search
patterns = {
    'JSR $EE1D':           bytes([0x20, TARGET_LO, TARGET_HI]),
    'JMP $EE1D':           bytes([0x4C, TARGET_LO, TARGET_HI]),
    'JSL ?:$EE1D':         bytes([0x22, TARGET_LO, TARGET_HI]),
    'JML ?:$EE1D':         bytes([0x5C, TARGET_LO, TARGET_HI]),
}
for name, pat in patterns.items():
    count = 0
    sites = []
    i = 0
    while True:
        j = data.find(pat, i)
        if j < 0: break
        rb = j // BANK_SIZE; ra = j % BANK_SIZE
        if name.startswith(('JSL', 'JML')) and j+3 < len(data):
            sites.append((rb, ra, data[j+3]))
        else:
            sites.append((rb, ra, None))
        count += 1
        i = j+1
    print(f'{name}: {count} occurrences')
    for s in sites[:8]:
        if s[2] is not None:
            print(f'  REU bank ${s[0]:02X} offset ${s[1]:04X}  bank-byte=${s[2]:02X}')
        else:
            print(f'  REU bank ${s[0]:02X} offset ${s[1]:04X}')
    if count > 8:
        print(f'  ... +{count-8} more')
    print()

# Banks with non-zero bytes near $EE1D
print('First 16 bytes at offset $EE1D in each non-empty bank:')
banks_seen = set()
for bank in range(len(data)//BANK_SIZE):
    base = bank * BANK_SIZE + 0xEE1D
    if base + 16 > len(data): break
    chunk = data[base:base+16]
    if any(b != 0 for b in chunk):
        hex_chunk = ' '.join(f'{b:02X}' for b in chunk)
        print(f'  bank ${bank:02X}:$EE1D  {hex_chunk}')
