#!/usr/bin/env python3
"""Scan bank $2D bytes for key opcodes."""
with open('C:/LLM/C64/MiSTerSuperCPU/doom.reu', 'rb') as f:
    data = f.read()

bank2d = data[0x2D0000:0x2E0000]
plp_count = bank2d.count(b'\x28')
rti_count = bank2d.count(b'\x40')
rts_count = bank2d.count(b'\x60')
rtl_count = bank2d.count(b'\x6B')
xce_count = bank2d.count(b'\xFB')
print(f'Bank $2D PLP (28) byte count: {plp_count}')
print(f'Bank $2D RTI (40) byte count: {rti_count}')
print(f'Bank $2D RTS (60) byte count: {rts_count}')
print(f'Bank $2D RTL (6B) byte count: {rtl_count}')
print(f'Bank $2D XCE (FB) byte count: {xce_count}')

# Same for bank $20
bank20 = data[0x200000:0x210000]
print()
print(f'Bank $20 PLP byte count: {bank20.count(b"\x28")}')
print(f'Bank $20 RTI byte count: {bank20.count(b"\x40")}')
print(f'Bank $20 XCE byte count: {bank20.count(b"\xFB")}')
