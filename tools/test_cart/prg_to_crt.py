#!/usr/bin/env python3
"""Wrap any PRG as a CBM80 auto-boot 8K cartridge.

PRG layout: 2-byte little-endian load address + payload bytes.

The wrapped cart contains:
  - CRT header (Normal cartridge, EXROM=0, GAME=1, 8K ROML at $8000)
  - Reset vector ($8000-$8001) -> $8009
  - NMI vector ($8002-$8003) -> RTI stub past bootstrap
  - CBM80 magic at $8004-$8008
  - Bootstrap at $8009: SEI / CLD / reset stack / copy payload to its load
    address via self-modifying page loop / JMP entry
  - Payload at $8100, padded to whole pages

Why this matters: lets us launch any bench without typing SYS at the BASIC
prompt. Eliminates the mtype.py dependency for one-shot benches that just
display a result. Load via OSD F1 browser or mbc load_rom <path> C64.CRT.

Default entry offset = 12 (skip the 12-byte SYS-style BASIC stub used by
gen_superram_bench helpers). Override with --entry-offset 0 for raw PRGs
that start executing at load_addr.
"""
import argparse
import os
import struct
import sys


def assemble_bootstrap(load_addr, pages, entry):
    """Return bytes for the 6502 bootstrap routine.

    Layout (starting at $8009):
      78          SEI
      D8          CLD
      A2 FF       LDX #$FF
      9A          TXS
      A2 00       LDX #$00
      A0 NN       LDY #pages
    loop:
      BD 00 81    LDA $8100,X            ; src page high byte self-modified
      9D 00 PL    STA load_page,X        ; dst page high byte self-modified
      E8          INX
      D0 F8       BNE loop               ; finish 256-byte page
      EE LL HH    INC src_hi             ; bump src high byte
      EE LL HH    INC dst_hi             ; bump dst high byte
      88          DEY
      D0 EE       BNE loop               ; more pages?
      4C LL HH    JMP entry
    """
    boot = bytearray()
    boot += bytes([0x78, 0xD8, 0xA2, 0xFF, 0x9A])      # SEI; CLD; LDX #$FF; TXS
    # Cart auto-boot skips KERNAL VIC init. Apply the minimum so any wrapped
    # bench that assumes RUN-from-BASIC can render. $D011=$1B (DEN=1, normal
    # mode), $D016=$C8 (CSEL=1, no multicolor), $D018=$14 (screen $0400,
    # chars $1000), $DD00=$97 lower 2 bits=11 (VIC bank 0). $0001=$37
    # (BASIC+KERNAL+I/O visible).
    boot += bytes([0xA9, 0x37, 0x85, 0x01])            # LDA #$37; STA $01 (BASIC+KERNAL+I/O visible)
    boot += bytes([0xA9, 0x1B, 0x8D, 0x11, 0xD0])      # LDA #$1B; STA $D011 (DEN=1)
    boot += bytes([0xA9, 0x14, 0x8D, 0x18, 0xD0])      # LDA #$14; STA $D018 (screen $0400 / chars $1000)
    boot += bytes([0xA2, 0x00, 0xA0, pages & 0xFF])    # LDX #$00; LDY #pages

    loop_off = len(boot)
    src_page_lo = 0x00       # always 0 (page-aligned src)
    src_page_hi = 0x81       # payload starts at $8100
    dst_page_lo = 0x00       # always 0 (we align dst to page)
    dst_page_hi = (load_addr >> 8) & 0xFF

    boot += bytes([0xBD, src_page_lo, src_page_hi])  # LDA $8100,X
    boot += bytes([0x9D, dst_page_lo, dst_page_hi])  # STA load_page,X
    boot += bytes([0xE8])                            # INX
    inner_bne_at = len(boot)
    inner_disp = loop_off - (inner_bne_at + 2)
    if not -128 <= inner_disp < 0:
        raise RuntimeError(f"inner branch disp out of range: {inner_disp}")
    boot += bytes([0xD0, inner_disp & 0xFF])         # BNE loop

    base = 0x8009  # absolute address of boot start
    src_hi_abs = base + loop_off + 2
    dst_hi_abs = base + loop_off + 5
    boot += bytes([0xEE, src_hi_abs & 0xFF, (src_hi_abs >> 8) & 0xFF])
    boot += bytes([0xEE, dst_hi_abs & 0xFF, (dst_hi_abs >> 8) & 0xFF])
    boot += bytes([0x88])                            # DEY

    bne_at = len(boot)
    disp = loop_off - (bne_at + 2)
    if not -128 <= disp < 0:
        raise RuntimeError(f"loop branch disp out of range: {disp}")
    boot += bytes([0xD0, disp & 0xFF])

    boot += bytes([0x4C, entry & 0xFF, (entry >> 8) & 0xFF])
    return boot


def make_boot_crt(prg_bytes, name="BENCH", entry_offset=12):
    if len(prg_bytes) < 3:
        raise ValueError("PRG too short (need 2-byte header + payload)")
    load_addr = prg_bytes[0] | (prg_bytes[1] << 8)
    payload = prg_bytes[2:]
    entry = load_addr + entry_offset

    page_lo = load_addr & 0xFF
    aligned = bytes(page_lo) + payload
    pages = (len(aligned) + 255) // 256
    aligned = aligned + bytes(pages * 256 - len(aligned))
    if pages < 1 or pages > 255:
        raise ValueError(f"payload pages out of range: {pages}")

    boot = assemble_bootstrap(load_addr, pages, entry)
    if 9 + len(boot) > 0x100:
        raise RuntimeError(
            f"bootstrap ({len(boot)} bytes) overlaps payload at $8100")

    rom = bytearray(8192)
    code_start = 0x8009
    rom[0] = code_start & 0xFF
    rom[1] = (code_start >> 8) & 0xFF
    rti_addr = code_start + len(boot)
    rom[2] = rti_addr & 0xFF
    rom[3] = (rti_addr >> 8) & 0xFF
    rom[4:9] = bytes([0xC3, 0xC2, 0xCD, 0x38, 0x30])
    rom[9:9 + len(boot)] = boot
    rom[rti_addr - 0x8000] = 0x40  # RTI
    payload_rom_off = 0x100
    end = payload_rom_off + len(aligned)
    if end > len(rom):
        raise ValueError(
            f"payload ({len(aligned)} bytes) exceeds 8K cart "
            f"(max {len(rom) - payload_rom_off})")
    rom[payload_rom_off:end] = aligned

    header = bytearray(64)
    header[0:16] = b'C64 CARTRIDGE   '
    struct.pack_into('>I', header, 16, 64)
    struct.pack_into('>H', header, 20, 0x0100)
    struct.pack_into('>H', header, 22, 0)        # normal cartridge
    header[24] = 0                                # EXROM=0
    header[25] = 1                                # GAME=1 (8K mode)
    name_b = name.encode('ascii')[:32]
    header[32:32 + len(name_b)] = name_b

    chip = bytearray(16)
    chip[0:4] = b'CHIP'
    struct.pack_into('>I', chip, 4, 16 + 8192)
    struct.pack_into('>H', chip, 8, 0)
    struct.pack_into('>H', chip, 10, 0)
    struct.pack_into('>H', chip, 12, 0x8000)
    struct.pack_into('>H', chip, 14, 0x2000)

    return bytes(header) + bytes(chip) + bytes(rom), {
        'load_addr': load_addr,
        'entry': entry,
        'pages_copied': pages,
        'bootstrap_size': len(boot),
        'payload_size': len(payload),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('prg', help='input PRG file (with 2-byte load address)')
    ap.add_argument('-o', '--out', help='output CRT path (default: <prg>.crt)')
    ap.add_argument('-n', '--name', default='BENCH', help='cart name')
    ap.add_argument('--entry-offset', type=int, default=12,
                    help='bytes past load_addr to JMP to (default 12 = skip '
                         'SYS-style BASIC stub; use 0 for raw PRGs)')
    args = ap.parse_args()

    with open(args.prg, 'rb') as f:
        prg = f.read()
    crt, info = make_boot_crt(prg, name=args.name,
                              entry_offset=args.entry_offset)
    out = args.out or os.path.splitext(args.prg)[0] + '.crt'
    with open(out, 'wb') as f:
        f.write(crt)
    print(f"  load_addr     ${info['load_addr']:04X}")
    print(f"  entry         ${info['entry']:04X}")
    print(f"  payload       {info['payload_size']} bytes")
    print(f"  pages copied  {info['pages_copied']}")
    print(f"  bootstrap     {info['bootstrap_size']} bytes")
    print(f"  -> {out} ({len(crt)} bytes)")


if __name__ == '__main__':
    main()
