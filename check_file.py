with open('asterix.prg','rb') as f:
    d = f.read()
print(f'file size: {len(d)} bytes (0x{len(d):X})')
print()
# File format: first 2 bytes = load addr, then data
# Memory M -> file offset (M - 0x801 + 2)
print('mem_addr  file_off  file_byte  (expected match for $XX94)')
for mem_hi in range(0x7F, 0x91):
    mem_addr = (mem_hi << 8) | 0x94
    file_off = mem_addr - 0x801 + 2
    if 0 <= file_off < len(d):
        print(f'  ${mem_addr:04X}    0x{file_off:04X}    ${d[file_off]:02X}')
    else:
        print(f'  ${mem_addr:04X}    0x{file_off:04X}    (past EOF)')
