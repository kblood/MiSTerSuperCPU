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

    Uses ZP-indirect ($FB/$FC src, $FD/$FE dst) addressing because the
    earlier abs,X + self-modifying-INC scheme is broken under cart-boot:
    INC of $80xx is a write to cart ROM (read-only) and silently fails,
    so for pages>=2 only the first page got copied and the rest of RAM
    held garbage -> CPU fetch from $0900+ wedged. Verified via 4-variant
    HW bisect 2026-05-23 (draw_v1..v4). Reproducer: tools/test_cart/
    gen_draw_bisect.py.

    Layout (starting at $8009):
      78           SEI
      D8           CLD
      A2 FF        LDX #$FF
      9A           TXS
      A9 7F 8D 0D DD  LDA #$7F; STA $DD0D    ; CIA2 NMI mask
      AD 0D DD     LDA $DD0D                  ; ack
      A9 37 85 01  LDA #$37; STA $01          ; BASIC+KERNAL+I/O
      A9 1B 8D 11 D0  LDA #$1B; STA $D011
      A9 14 8D 18 D0  LDA #$14; STA $D018
      A9 00 85 FB  LDA #$00; STA $FB          ; src lo
      A9 81 85 FC  LDA #$81; STA $FC          ; src hi (cart $8100)
      A9 00 85 FD  LDA #$00; STA $FD          ; dst lo
      A9 PL 85 FE  LDA #<load_page>; STA $FE  ; dst hi
      A0 00        LDY #$00
      A2 PG        LDX #pages
    loop:
      B1 FB        LDA ($FB),Y                ; ZP-indirect read
      91 FD        STA ($FD),Y                ; ZP-indirect write
      C8           INY
      D0 F9        BNE loop                   ; finish 256-byte page
      E6 FC        INC $FC                    ; bump src hi (RAM, works!)
      E6 FE        INC $FE                    ; bump dst hi
      CA           DEX
      D0 F1        BNE loop
      4C LL HH     JMP entry
    """
    boot = bytearray()
    boot += bytes([0x78, 0xD8, 0xA2, 0xFF, 0x9A])      # SEI; CLD; LDX #$FF; TXS
    boot += bytes([0xA9, 0x7F, 0x8D, 0x0D, 0xDD])      # LDA #$7F; STA $DD0D (mask CIA2 NMI)
    boot += bytes([0xAD, 0x0D, 0xDD])                  # LDA $DD0D (ack pending)
    boot += bytes([0xA9, 0x37, 0x85, 0x01])            # LDA #$37; STA $01
    boot += bytes([0xA9, 0x1B, 0x8D, 0x11, 0xD0])      # LDA #$1B; STA $D011 (DEN=1)
    boot += bytes([0xA9, 0x14, 0x8D, 0x18, 0xD0])      # LDA #$14; STA $D018

    # ZP pointers: $FB/$FC src, $FD/$FE dst.
    boot += bytes([0xA9, 0x00, 0x85, 0xFB])            # LDA #$00; STA $FB
    boot += bytes([0xA9, 0x81, 0x85, 0xFC])            # LDA #$81; STA $FC
    boot += bytes([0xA9, 0x00, 0x85, 0xFD])            # LDA #$00; STA $FD
    boot += bytes([0xA9, (load_addr >> 8) & 0xFF, 0x85, 0xFE])  # LDA #ph; STA $FE
    boot += bytes([0xA0, 0x00])                        # LDY #$00
    boot += bytes([0xA2, pages & 0xFF])                # LDX #pages

    loop_off = len(boot)
    boot += bytes([0xB1, 0xFB])                        # LDA ($FB),Y
    boot += bytes([0x91, 0xFD])                        # STA ($FD),Y
    boot += bytes([0xC8])                              # INY
    inner_bne_at = len(boot)
    inner_disp = loop_off - (inner_bne_at + 2)
    if not -128 <= inner_disp < 0:
        raise RuntimeError(f"inner branch disp out of range: {inner_disp}")
    boot += bytes([0xD0, inner_disp & 0xFF])           # BNE loop

    boot += bytes([0xE6, 0xFC])                        # INC $FC (src hi)
    boot += bytes([0xE6, 0xFE])                        # INC $FE (dst hi)
    boot += bytes([0xCA])                              # DEX

    bne_at = len(boot)
    disp = loop_off - (bne_at + 2)
    if not -128 <= disp < 0:
        raise RuntimeError(f"loop branch disp out of range: {disp}")
    boot += bytes([0xD0, disp & 0xFF])                 # BNE loop

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
