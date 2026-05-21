with open('asterix.prg','rb') as f:
    d = f.read()

# See if $48 and $06 (hw reads at $8094 and $8194) might come from elsewhere in file
# $8094 file offset would be 0x7895 (expected $51, got $48)
# Check neighboring offsets
print(f'Around file offset 0x7895 (expected for $8094=$51):')
for off in range(0x7880, 0x78B0):
    print(f'  [0x{off:04X}] = ${d[off]:02X}')

print()
print(f'Around file offset 0x7995 (expected for $8194=$49):')
for off in range(0x7980, 0x79B0):
    print(f'  [0x{off:04X}] = ${d[off]:02X}')
