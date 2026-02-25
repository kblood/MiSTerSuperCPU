import re
mif_path = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\roms\std_C64.mif'
rom = {}
with open(mif_path, 'r') as f: content = f.read()
for m in re.finditer(r'(\S+)\s*:\s*([0-9A-Fa-f]+)\s*;', content):
    a, v = m.group(1), int(m.group(2), 16)
    rm = re.match(r'\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]', a)
    if rm:
        for x in range(int(rm.group(1),16), int(rm.group(2),16)+1): rom[x] = v
    else: rom[int(a, 16)] = v

def rb(addr):
    if 0xE000 <= addr <= 0xFFFF: return rom.get(addr-0xE000+0x2000, 0)
    if 0xA000 <= addr <= 0xBFFF: return rom.get(addr-0xA000, 0)
    return 0

# The code sets F5/F6 = $EB81 for unshifted table
table = [rb(0xEB81+i) for i in range(0x50)]  # read 80 bytes including past table end

print("=== Unshifted table @ EB81, 64 entries (cols 0-7, rows 0-7) ===")
for i in range(8):
    row = []
    for j in range(8):
        b = table[i*8+j]
        c = chr(b) if 0x20 <= b <= 0x7E else '.'
        row.append("%02X(%s)" % (b, c))
    print("  Col%d: %s" % (i, "  ".join(row)))

print()
idx = 0x40
addr = 0xEB81 + idx
b = table[idx]
c = chr(b) if 0x20 <= b <= 0x7E else '.'
print("POSITION 0x40 (CB initial value) -> addr $%04X = %02X (%s)" % (addr, b, c))
print("If this is '@' (0x40=64 decimal), that explains scrolling '@'!")
print()

print("=== Bytes around EBC1 (just past 64-entry table) ===")
for a in range(0xEBBE, 0xEBCE):
    b = rb(a)
    c = chr(b) if 0x20 <= b <= 0x7E else '.'
    print("  $%04X: %02X  %s" % (a, b, c))

print()
print("=== Check KERNAL vector init area - look for 028F init ===")
# CINT is at E518, let's look there
for a in range(0xE518, 0xE560):
    b = rb(a)
    print("  $%04X: %02X" % (a, b), end="")
    if (a-0xE518) % 8 == 7: print()
print()
