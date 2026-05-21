#!/usr/bin/env python3
"""Generate peek_e9c0.prg.

Reads $87:$E9C0..$E9CF from SDRAM (where Doom's error dispatcher at
$20:$8FE6 et al. save error args $88/$8A long abs). After Doom prints
"Bad music number -9" and halts, the music_num arg should be at:
  $87:$E9C8/E9C9 = music_num 16-bit (saved by $8FE6 dispatcher)
  $87:$E9CC/E9CD = saved by $8FB9 dispatcher
  ... etc.

Layout (40 col, screen-codes):
  Row  0: '87:E9C0 XX XX XX XX XX XX XX XX'  (offsets 0..7)
  Row  2: '87:E9C8 XX XX XX XX XX XX XX XX'  (offsets 8..F)
  Row  4: '87:EAC0 XX XX XX XX XX XX XX XX'
  Row  6: '87:EAC8 XX XX XX XX XX XX XX XX'

Loaded via MGL after Doom has run. SDRAM bank $01..$FF persists.
"""
import os, struct

def sc_char(ch: str) -> int:
    if 'A' <= ch <= 'Z':
        return 0x01 + ord(ch) - ord('A')
    if '0' <= ch <= '9':
        return 0x30 + ord(ch) - ord('0')
    if ch == ':':
        return 0x3A
    return 0x20

prg = bytearray()
prg += struct.pack('<H', 0x0801)
prg += b'\x0B\x08'
prg += b'\x0A\x00'
prg += b'\x9E2061\x00'
prg += b'\x00\x00'

code = bytearray()
def emit(*bs):
    for b in bs: code.append(b)

emit(0x78)
emit(0xA9, 0x35, 0x85, 0x01)
emit(0xA9, 0x80)
emit(0x8D, 0x7E, 0xD0)
emit(0x8D, 0x7B, 0xD0)
emit(0x18, 0xFB)
emit(0xE2, 0x30)

def emit_store(scr_addr, sc):
    emit(0xA9, sc)
    emit(0x8D, scr_addr & 0xFF, (scr_addr >> 8) & 0xFF)

def emit_label(s, scr_addr):
    for ch in s:
        emit_store(scr_addr, sc_char(ch))
        scr_addr += 1

def nibble_to_screencode():
    emit(0x29, 0x0F)
    emit(0xC9, 0x0A)
    emit(0x90, 0x05)
    emit(0x38)
    emit(0xE9, 0x09)
    emit(0x80, 0x03)
    emit(0x18)
    emit(0x69, 0x30)

def emit_hex_byte_full(src_bank, src_addr16, scr_addr):
    src_lo = src_addr16 & 0xFF
    src_hi = (src_addr16 >> 8) & 0xFF
    emit(0xAF, src_lo, src_hi, src_bank)
    emit(0x85, 0x80)
    emit(0x4A, 0x4A, 0x4A, 0x4A)
    nibble_to_screencode()
    emit(0x8D, scr_addr & 0xFF, (scr_addr >> 8) & 0xFF)
    emit(0xA5, 0x80)
    nibble_to_screencode()
    sa = scr_addr + 1
    emit(0x8D, sa & 0xFF, (sa >> 8) & 0xFF)

rows = [
    (0x87, 0xE9C0, 0x0400, '87:E9C0'),
    (0x87, 0xE9C8, 0x0428, '87:E9C8'),
    (0x87, 0xEAC0, 0x0450, '87:EAC0'),
    (0x87, 0xEAC8, 0x0478, '87:EAC8'),
]
for src_bank, src_base, scr_row_base, label in rows:
    emit_label(label, scr_row_base)
    emit_store(scr_row_base + 7, 0x20)
    for i in range(8):
        emit_hex_byte_full(src_bank, src_base + i, scr_row_base + 8 + i*3)
        emit_store(scr_row_base + 8 + i*3 + 2, 0x20)

loop_addr = 0x080D + len(code)
emit(0x4C, loop_addr & 0xFF, (loop_addr >> 8) & 0xFF)

prg += code

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_e9c0.prg')
with open(out_path, 'wb') as f:
    f.write(prg)
print(f'Wrote {out_path}: {len(prg)} bytes')
