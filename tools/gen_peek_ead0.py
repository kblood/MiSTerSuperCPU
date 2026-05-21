#!/usr/bin/env python3
"""Generate peek_ead0.prg.

After v289 found the music-check at $2B:$1A23 isn't on the error path, but
disassembly of $2C:$85B6 shows `LDA $87:$EAD8 / STA $88; LDA $87:$EADA /
STA $8A`, suggesting $87:$EAD8/$EADA hold persistent error-context bytes
(saved $88/$8A) — these survive across core reload (SuperRAM bank $87
persists). Read $87:$EAD0..$EAEF on screen.

Layout (40 col, screencodes):
  Row  0: '87:EAD0 XX XX XX XX XX XX XX XX'
  Row  2: '87:EAD8 XX XX XX XX XX XX XX XX'  ← E9D8/EADA = saved $88/$8A
  Row  4: '87:EAE0 XX XX XX XX XX XX XX XX'
  Row  6: '87:EAE8 XX XX XX XX XX XX XX XX'
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
    (0x87, 0xEAD0, 0x0400, '87:EAD0'),
    (0x87, 0xEAD8, 0x0428, '87:EAD8'),
    (0x87, 0xEAE0, 0x0450, '87:EAE0'),
    (0x87, 0xEAE8, 0x0478, '87:EAE8'),
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

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_ead0.prg')
with open(out_path, 'wb') as f:
    f.write(prg)
print(f'Wrote {out_path}: {len(prg)} bytes')
