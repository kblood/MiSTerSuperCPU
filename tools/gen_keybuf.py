#!/usr/bin/env python3
"""Launch Doom by injecting code + keyboard buffer via mbc load_rom.

No keyboard input needed! Uses three PRG injections:
1. doom_loader.prg at $C000 (doom launcher machine code)
2. keybuf.prg at $0277 (keyboard buffer: "SYS49152" + RETURN)
3. keycount.prg at $00C6 (keyboard count: 9)

After step 3, BASIC processes the buffer and auto-types "SYS49152".
"""
import struct, os, sys

# --- Generate keybuf.prg: keyboard buffer at $0277 ---
# C64 keyboard buffer holds PETSCII characters
keybuf_addr = 0x0277
keybuf_text = "SYS49152"
keybuf_data = bytes([ord(c) for c in keybuf_text]) + bytes([0x0D])  # + RETURN
keybuf_prg = struct.pack('<H', keybuf_addr) + keybuf_data
with open('keybuf.prg', 'wb') as f:
    f.write(keybuf_prg)
print(f"Generated keybuf.prg: {len(keybuf_prg)} bytes, loads at ${keybuf_addr:04X}")
print(f"  Data: {' '.join(f'{b:02X}' for b in keybuf_data)}")

# --- Generate keycount.prg: keyboard buffer count at $00C6 ---
keycount_addr = 0x00C6
keycount_data = bytes([len(keybuf_data)])  # 9 chars
keycount_prg = struct.pack('<H', keycount_addr) + keycount_data
with open('keycount.prg', 'wb') as f:
    f.write(keycount_prg)
print(f"Generated keycount.prg: {len(keycount_prg)} bytes, loads at ${keycount_addr:04X}")
print(f"  Count: {len(keybuf_data)}")

# --- Generate simple test: just keyboard buffer 'A' + return ---
test_addr = 0x0277
test_data = bytes([0x41, 0x0D])  # 'A' + RETURN
test_prg = struct.pack('<H', test_addr) + test_data
with open('test_keybuf.prg', 'wb') as f:
    f.write(test_prg)

test_count_addr = 0x00C6
test_count_data = bytes([2])
test_count_prg = struct.pack('<H', test_count_addr) + test_count_data
with open('test_keycount.prg', 'wb') as f:
    f.write(test_count_prg)
print(f"Generated test PRGs for 'A' + RETURN")

print("\nFull launch sequence:")
print("  1. python tools/mister_debug.py load_prg doom_loader.prg")
print("  2. python tools/mister_debug.py load_prg keybuf.prg")
print("  3. python tools/mister_debug.py load_prg keycount.prg")
print("  (BASIC auto-types SYS49152 and launches Doom)")
