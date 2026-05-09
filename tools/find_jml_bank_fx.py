"""Find JML/JSL instructions in doom.reu whose target bank is $F0-$FF.

JML = $5C, operand = 3 bytes (PCL, PCH, PB)
JSL = $22, operand = 3 bytes (PCL, PCH, PB)

If Doom statically references bank $F0-$FF, those occurrences will show
up here. Zero matches = the bank-$FC wedge is reached dynamically (via
a RAM-resolved indirect jump or a bad RTL/RTI).
"""
import sys

REU = sys.argv[1] if len(sys.argv) > 1 else 'doom.reu'
BANK_SIZE = 0x10000

with open(REU, 'rb') as f:
    data = f.read()

print(f'{REU}: {len(data):,} bytes ({len(data)//BANK_SIZE} banks)')
print()

# Find all JML/JSL with bank $F0-$FF
for opname, opcode in [('JML', 0x5C), ('JSL', 0x22)]:
    sites = []
    for i in range(len(data) - 3):
        if data[i] == opcode:
            tgt_lo, tgt_hi, tgt_bk = data[i+1], data[i+2], data[i+3]
            if 0xF0 <= tgt_bk <= 0xFF:
                sites.append((i, tgt_lo, tgt_hi, tgt_bk))
    print(f'{opname} ?:$XXXX where bank in $F0..$FF: {len(sites)} occurrences')
    for (i, lo, hi, bk) in sites[:20]:
        rb = i // BANK_SIZE; ra = i % BANK_SIZE
        print(f'  REU bank ${rb:02X} offset ${ra:04X}  ->  ${bk:02X}:${hi:02X}{lo:02X}')
    if len(sites) > 20:
        print(f'  ... +{len(sites)-20} more')
    print()
