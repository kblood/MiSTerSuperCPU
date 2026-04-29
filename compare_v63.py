import re

with open('asterix.prg','rb') as f:
    d = f.read()

# Parse v63 TR lines - only reader=$083F (phase-1 source reads)
captures = {}
with open('v63_tr.txt') as f:
    for line in f:
        m = re.search(r'TR:(\w\w) PC:(\w{4}) K:(\w\w) I:3F P:08', line)
        if m:
            tr_idx = int(m.group(1), 16)
            addr = int(m.group(2), 16)
            data = int(m.group(3), 16)
            captures[addr] = (tr_idx, data)

print(f'captured {len(captures)} source reads at \$XX94')
print()
print('addr   hw    expected  match')
mismatches = []
for addr in sorted(captures.keys()):
    tr, hw = captures[addr]
    file_off = addr - 0x801 + 2
    if 0 <= file_off < len(d):
        expected = d[file_off]
        ok = 'OK' if hw == expected else 'XX'
        if hw != expected:
            mismatches.append((addr, hw, expected))
        print(f'  ${addr:04X}  ${hw:02X}    ${expected:02X}       {ok}')
    else:
        print(f'  ${addr:04X}  ${hw:02X}    (past EOF)')

print()
print(f'Total mismatches: {len(mismatches)}')
if mismatches:
    print(f'Range: ${mismatches[0][0]:04X} .. ${mismatches[-1][0]:04X}')
    print(f'All-FF mismatches: {sum(1 for a,h,e in mismatches if h==0xFF)}/{len(mismatches)}')
