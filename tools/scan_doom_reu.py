#!/usr/bin/env python3
"""Find the game code in doom.reu and understand the file layout."""
with open('doom.reu', 'rb') as f:
    data = f.read()

print(f'File size: {len(data)} bytes ({len(data)/1024/1024:.1f} MB)')
print(f'First 32 bytes: {data[:32].hex()}')

# Find first non-zero byte
for i in range(len(data)):
    if data[i] != 0:
        print(f'First non-zero byte at offset 0x{i:06X} = 0x{data[i]:02X}')
        print(f'Bytes at that offset: {data[i:i+32].hex()}')
        break
else:
    print("File is all zeros!")

# Check if SEI+CLD+CLC+XCE appears anywhere
target = bytes([0x78, 0xD8, 0x18, 0xFB])
pos = data.find(target)
if pos >= 0:
    print(f'Found SEI+CLD+CLC+XCE at offset 0x{pos:06X}')
    print(f'Context (64 bytes): {data[pos:pos+64].hex()}')
else:
    print('SEI+CLD+CLC+XCE pattern NOT found')

# Check at various offsets
for off in [0, 0x10000, 0x20000, 0x1E0000, 0x1F0000]:
    if off < len(data):
        snippet = data[off:off+16]
        nonzero = sum(1 for b in snippet if b != 0)
        print(f'Offset 0x{off:06X}: {" ".join(f"{b:02X}" for b in snippet)} (nonzero={nonzero})')

# Scan for non-zero blocks in 4KB chunks
print("\nNon-zero 4KB blocks:")
for i in range(0, len(data), 4096):
    chunk = data[i:i+4096]
    nz = sum(1 for b in chunk if b != 0)
    if nz > 0:
        first_nz = next(j for j in range(len(chunk)) if chunk[j] != 0)
        print(f'  0x{i:06X}-0x{i+4095:06X}: {nz} non-zero bytes, first at +0x{first_nz:03X} = 0x{chunk[first_nz]:02X}')
        if nz < 20:
            # Show all non-zero
            for j in range(len(chunk)):
                if chunk[j] != 0:
                    print(f'    0x{i+j:06X} = 0x{chunk[j]:02X}')
