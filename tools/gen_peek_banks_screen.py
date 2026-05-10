#!/usr/bin/env python3
"""Generate peek_banks_screen.prg.

Reads $00:$6C00..$6C07, $01:$6C00..$6C07, $20:$0000..$0007,
$2A:$6C00..$6C07 from SuperRAM/RAM and writes the bytes as
ASCII hex on the screen at $0400+.

Layout (40 col, screen-codes):
  Row  0: '00:6C00 XX XX XX XX XX XX XX XX'
  Row  2: '01:6C00 XX XX XX XX XX XX XX XX'
  Row  4: '20:0000 XX XX XX XX XX XX XX XX'
  Row  6: '2A:6C00 XX XX XX XX XX XX XX XX'

Loaded via MGL after Doom has run + populated SuperRAM.
SDRAM (banks $01..$FF) persists across core reload; bank $00
motherboard RAM is reset to BASIC-init state on reload.
"""
import os, struct

# Screen-code lookup ('0'..'9' = $30..$39, 'A'..'Z' = $01..$1A,
# ':' = $3A, ' ' = $20).
def sc_char(ch: str) -> int:
    if 'A' <= ch <= 'Z':
        return 0x01 + ord(ch) - ord('A')
    if '0' <= ch <= '9':
        return 0x30 + ord(ch) - ord('0')
    if ch == ':':
        return 0x3A
    return 0x20  # space / fallback

prg = bytearray()
prg += struct.pack('<H', 0x0801)
# BASIC SYS 2061 stub at $0801..$080C (12 bytes).
prg += b'\x0B\x08'        # next-line ptr
prg += b'\x0A\x00'        # line 10
prg += b'\x9E2061\x00'    # SYS 2061
prg += b'\x00\x00'        # end
assert len(prg) - 2 + 0x0801 == 0x080D

# Code at $080D.
code = bytearray()
def emit(*bs):
    for b in bs: code.append(b)

# ---- Init: native 65C816, 8-bit M, 16-bit X (X=8-bit also, simpler).
emit(0x78)                          # SEI
emit(0xA9, 0x35, 0x85, 0x01)        # LDA #$35; STA $01 (bank out KERNAL → RAM at $D0xx? no, IO still visible)
emit(0xA9, 0x80)                    # LDA #$80
emit(0x8D, 0x7E, 0xD0)              # STA $D07E (SCPU enable)
emit(0x8D, 0x7B, 0xD0)              # STA $D07B (20 MHz turbo)
emit(0x18, 0xFB)                    # CLC; XCE → native mode
emit(0xE2, 0x30)                    # SEP #$30 → 8-bit M, 8-bit X

def emit_store(scr_addr: int, sc: int):
    emit(0xA9, sc)                                   # LDA #imm
    emit(0x8D, scr_addr & 0xFF, (scr_addr >> 8) & 0xFF)  # STA abs

def emit_label(s: str, scr_addr: int):
    for ch in s:
        emit_store(scr_addr, sc_char(ch))
        scr_addr += 1

def emit_hex_byte(src_bank: int, src_low: int, scr_addr: int):
    """Read $bank:$6C(src_low) (or $bank:src_low) and write 2 PETSCII hex chars
    to scr_addr, scr_addr+1. src_low here is the LOW byte of the address.
    Caller passes a 16-bit address split into (src_high, src_low) via separate
    LDA — see emit_hex_byte_full."""
    raise NotImplementedError("use emit_hex_byte_full")

def nibble_to_screencode():
    """Convert nibble in A (0..15) to screencode in A.
    n<10 → $30+n ; n>=10 → $01+(n-10)."""
    emit(0x29, 0x0F)              # AND #$0F
    emit(0xC9, 0x0A)              # CMP #$0A
    emit(0x90, 0x05)              # BCC +5 → digit branch
    # alpha: SEC; SBC #$09  → A=$01..$06    (3 bytes)
    emit(0x38)                    # SEC
    emit(0xE9, 0x09)              # SBC #$09
    emit(0x80, 0x03)              # BRA +3 → done
    # digit: CLC; ADC #$30  → A=$30..$39   (3 bytes)
    emit(0x18)                    # CLC
    emit(0x69, 0x30)              # ADC #$30

def emit_hex_byte_full(src_bank: int, src_addr16: int, scr_addr: int):
    """Read $bank:$src_addr16 (long, 24-bit pointer) and write 2 PETSCII hex
    chars to scr_addr, scr_addr+1."""
    src_lo = src_addr16 & 0xFF
    src_hi = (src_addr16 >> 8) & 0xFF
    emit(0xAF, src_lo, src_hi, src_bank)   # LDA long
    emit(0x85, 0x80)                       # STA $80 (save byte)
    # high nibble
    emit(0x4A, 0x4A, 0x4A, 0x4A)           # LSR ×4
    nibble_to_screencode()
    emit(0x8D, scr_addr & 0xFF, (scr_addr >> 8) & 0xFF)
    # low nibble
    emit(0xA5, 0x80)                       # LDA $80
    nibble_to_screencode()
    sa = scr_addr + 1
    emit(0x8D, sa & 0xFF, (sa >> 8) & 0xFF)

rows = [
    (0x00, 0x6C00, 0x0400, '00:6C00'),
    (0x01, 0x6C00, 0x0428, '01:6C00'),
    (0x20, 0x0000, 0x0450, '20:0000'),
    (0x2A, 0x6C00, 0x0478, '2A:6C00'),
]
for src_bank, src_base, scr_row_base, label in rows:
    emit_label(label, scr_row_base)
    # space separator after label
    emit_store(scr_row_base + 7, 0x20)
    for i in range(8):
        emit_hex_byte_full(src_bank, src_base + i, scr_row_base + 8 + i*3)
        emit_store(scr_row_base + 8 + i*3 + 2, 0x20)  # space between bytes

# infinite loop
loop_addr = 0x080D + len(code)
emit(0x4C, loop_addr & 0xFF, (loop_addr >> 8) & 0xFF)

prg += code

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_banks_screen.prg')
with open(out_path, 'wb') as f:
    f.write(prg)
print(f'Wrote {out_path}: {len(prg)} bytes')
print(f'Code size: {len(code)} bytes; ends at ${0x0801 + len(prg) - 1:04X}')
