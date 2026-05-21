import re

with open('asterix.prg','rb') as f:
    d = f.read()

# Phase-1 writes TO dest page; src has LOW byte $94 offset
# dst_y = write_addr_low (Y index)
# src_addr = (src_page << 8) | $94 + Y, wrapping into next page
# For dst_page = $8E, src_page = $4D
# When Y=0: src=$4D94, writes dst=$8E00
# When Y=$6B: src=$4DFF, writes dst=$8E6B
# When Y=$6C: src=$4E00, writes dst=$8E6C

captures = {}
with open('v65_tr.txt') as f:
    for line in f:
        m = re.search(r'TR:(\w\w) PC:(\w{4}) K:(\w\w) I:(\w\w) P:(\w\w)', line)
        if m:
            addr = int(m.group(2), 16)
            data = int(m.group(3), 16)
            captures[addr] = data

# Determine src page based on dst page
# dst_page = $00 - N mod 256 → N = ($100 - dst_page) mod 256
# src_page = $BF - N mod 256
def src_addr_for_dst(dst_addr):
    dst_page = (dst_addr >> 8) & 0xFF
    y = dst_addr & 0xFF
    n = (0x100 - dst_page) & 0xFF
    src_page = (0xBF - n) & 0xFF
    src_base = (src_page << 8) | 0x94  # initial src pointer
    # Add Y, wrap mod $10000
    return (src_base + y) & 0xFFFF

# Validate: for dst=$8E00, src should be $4D94
print(f'Sanity: src for $8E00 = ${src_addr_for_dst(0x8E00):04X} (expect $4D94)')
print(f'Sanity: src for $8E6B = ${src_addr_for_dst(0x8E6B):04X} (expect $4DFF)')
print(f'Sanity: src for $8E6C = ${src_addr_for_dst(0x8E6C):04X} (expect $4E00)')
print()

print('Compare v65 write data to expected asterix.prg byte at src:')
print('dst      hw  src      exp  match')
mismatches = 0
for addr in sorted(captures.keys())[:20]:
    hw = captures[addr]
    src = src_addr_for_dst(addr)
    src_off = src - 0x801 + 2
    if 0 <= src_off < len(d):
        exp = d[src_off]
        ok = 'OK' if hw == exp else 'XX'
        if hw != exp: mismatches += 1
        print(f'  ${addr:04X}   ${hw:02X}  ${src:04X}   ${exp:02X}   {ok}')
    else:
        print(f'  ${addr:04X}   ${hw:02X}  ${src:04X}   EOF   --')

print()
mismatches = []
for addr in sorted(captures.keys()):
    hw = captures[addr]
    src = src_addr_for_dst(addr)
    src_off = src - 0x801 + 2
    if 0 <= src_off < len(d):
        if hw != d[src_off]:
            mismatches.append((addr, hw, d[src_off], src))
print(f'Total mismatches: {len(mismatches)}/{len(captures)}')
if mismatches[:5]:
    print('First 5 mismatches:')
    for addr, hw, exp, src in mismatches[:5]:
        print(f'  ${addr:04X} wrote ${hw:02X}, expected ${exp:02X} from src ${src:04X}')
