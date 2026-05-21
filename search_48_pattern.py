with open('asterix.prg','rb') as f:
    d = f.read()

# Find all places where PRG has byte sequence matching $48 at position N such that
# N maps to $80XX memory
# $8094 got $48. $48 consecutive bytes in file:
print('Occurrences of 0x48 at memory $XX94 in file:')
for mem_hi in range(0x08, 0xBA):
    mem_addr = (mem_hi << 8) | 0x94
    file_off = mem_addr - 0x801 + 2
    if 0 <= file_off < len(d) and d[file_off] == 0x48:
        print(f'  ${mem_addr:04X} (file 0x{file_off:04X}) = $48')

print()
# Where is $48 $06 together in the file?
print("Searching for $48 $06 pairs:")
for i in range(len(d)-1):
    if d[i] == 0x48 and d[i+1] == 0x06:
        mem_addr = i + 0x801 - 2
        print(f'  file[0x{i:04X}] = $48 $06 (if at PRG mem base = ${mem_addr:04X})')

print()
# Where does asterix.prg have FF FF FF FF (uninitialized area)?
print("Searching for long $FF runs (8+ bytes):")
i = 0
while i < len(d) - 8:
    if all(d[i+j] == 0xFF for j in range(8)):
        start = i
        while i < len(d) and d[i] == 0xFF:
            i += 1
        mem_start = start + 0x801 - 2
        mem_end = i + 0x801 - 2
        print(f'  file[0x{start:04X}..0x{i-1:04X}] = ${mem_start:04X}..${mem_end-1:04X} ({i-start} bytes)')
    else:
        i += 1
