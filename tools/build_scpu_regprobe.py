#!/usr/bin/env python3
"""build_scpu_regprobe.py — SCPU detection/status register conformance probe.

Emulation-mode 6502 PRG (no XCE) that mimics what a real SuperCPU-aware
detection library does: write $D07E to enable the hardware-register window,
then read the status/detect register set. Each byte is stored to scratch RAM
$C000.. (for exact capture via VICE's remote monitor `m c000 c010`) AND painted
as hex on screen rows 0-1 (for HW screenshot capture and VICE screenshot).

Registers probed (order = scratch offset = screen column pair on row 0):
  off  reg     meaning (spec)
  $00  $D0B0   mode detect      b7-6: 00=v2/128, 01=v2/64, 11=v1/none  (expect $40)
  $01  $D0B2   HW-enable+sys1MHz (expect b7=hwenable -> $80 after $D07E)
  $02  $D0B3   enhanced optim (V2)
  $03  $D0B4   optimization mode flags
  $04  $D0B5   JiffyDOS / CPU speed switch
  $05  $D0B6   bit7 = emulation mode (1=6502)
  $06  $D0B8   software speed flag
  $07  $D0BC   DOS extension mode   (DETECTION Method 1: bit7==0 => SuperCPU)
  $08  $D07E   HW register enable (read-back)
  $09  $D078   SIMM config / (MiSTer: cache-flush) read-back

Screen row 0 = $D0B0,$D0B2,$D0B3,$D0B4,$D0B5  (5 hex pairs, cols 0-9)
Screen row 1 = $D0B6,$D0B8,$D0BC,$D07E,$D078  (5 hex pairs, cols 0-9 of row 1 @ $0428)

Build: python tools/build_scpu_regprobe.py  -> tools/scpu_regprobe.prg
"""
import os, struct, sys

REGS = [
    ("D0B0", 0xD0B0), ("D0B2", 0xD0B2), ("D0B3", 0xD0B3), ("D0B4", 0xD0B4),
    ("D0B5", 0xD0B5), ("D0B6", 0xD0B6), ("D0B8", 0xD0B8), ("D0BC", 0xD0BC),
    ("D07E", 0xD07E), ("D078", 0xD078),
]
SCRATCH = 0xC000


def main():
    code = bytearray()
    # BASIC SYS 2061 stub at $0801
    stub = bytes([0x0B, 0x08, 0x00, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31,
                  0x00, 0x00, 0x00])
    code += stub

    def addr_of(o): return 0x0801 + o
    def emit(*bs): code.extend(bs)
    assert addr_of(len(code)) == 0x080D

    emit(0x78)                      # SEI

    # Enable the SCPU hardware-register window: a WRITE to $D07E.
    # (value irrelevant; the address decode performs the enable)
    emit(0xA9, 0x00)                # LDA #$00
    emit(0x8D, 0x7E, 0xD0)          # STA $D07E

    # Read each register into scratch $C000+off
    for off, (_name, addr) in enumerate(REGS):
        emit(0xAD, addr & 0xFF, (addr >> 8) & 0xFF)   # LDA abs
        emit(0x8D, (SCRATCH + off) & 0xFF, ((SCRATCH + off) >> 8) & 0xFF)  # STA

    # Clear screen rows 0 and 1 to spaces
    emit(0xA9, 0x20)                # LDA #$20 (space)
    emit(0xA2, 0x00)                # LDX #0
    lp = addr_of(len(code))
    emit(0x9D, 0x00, 0x04)          # STA $0400,X
    emit(0x9D, 0x28, 0x04)          # STA $0428,X
    emit(0xE8)                      # INX
    emit(0xE0, 0x28)                # CPX #$28
    bpc = addr_of(len(code) + 2); emit(0xD0, (lp - bpc) & 0xFF)  # BNE lp

    # Paint a byte (in A) as two hex chars at screen $base / $base+1.
    # Uses a tiny inline routine; we inline per byte for simplicity.
    def paint_at(zp_scratch_off, screen_addr):
        # load byte
        emit(0xAD, (SCRATCH + zp_scratch_off) & 0xFF,
             ((SCRATCH + zp_scratch_off) >> 8) & 0xFF)   # LDA scratch+off
        # high nibble
        emit(0x4A); emit(0x4A); emit(0x4A); emit(0x4A)   # LSR x4
        emit(0xC9, 0x0A); emit(0x90, 0x05)               # CMP #$0A; BCC +5
        emit(0x38); emit(0xE9, 0x09)                     # SEC; SBC #$09  (A-F)
        emit(0x80, 0x03)                                 # BRA-> use BPL? 6502: BVC? use BNE? -> use plain branch
        # NOTE: 6502 has no BRA; emulate skip with CLC;ADC done below.
        # The two-way: BCC took digit path (skip SEC/SBC). We need an
        # unconditional skip over the digit-add. Use 0x80 = BRA only on
        # 65C02/65C816 (emulation mode supports BRA $80). Our CPU is 65C816
        # so BRA works in emulation mode. offset 3 skips CLC;ADC #$30.
        emit(0x18); emit(0x69, 0x30)                     # CLC; ADC #$30 (0-9)
        emit(0x8D, screen_addr & 0xFF, (screen_addr >> 8) & 0xFF)  # STA screen
        # low nibble
        emit(0xAD, (SCRATCH + zp_scratch_off) & 0xFF,
             ((SCRATCH + zp_scratch_off) >> 8) & 0xFF)
        emit(0x29, 0x0F)                                 # AND #$0F
        emit(0xC9, 0x0A); emit(0x90, 0x05)
        emit(0x38); emit(0xE9, 0x09)
        emit(0x80, 0x03)
        emit(0x18); emit(0x69, 0x30)
        emit(0x8D, (screen_addr + 1) & 0xFF, ((screen_addr + 1) >> 8) & 0xFF)

    # Row 0: regs 0..4 at cols 0,2,4,6,8 ($0400..)
    for i in range(5):
        paint_at(i, 0x0400 + i * 2)
    # Row 1: regs 5..9 at cols 0,2,4,6,8 ($0428..)
    for i in range(5):
        paint_at(5 + i, 0x0428 + i * 2)

    # Border/background = green to signal "probe completed"
    emit(0xA9, 0x05); emit(0x8D, 0x20, 0xD0)   # LDA #5; STA $D020
    emit(0xA9, 0x00); emit(0x8D, 0x21, 0xD0)   # LDA #0; STA $D021

    # Spin forever
    spin = addr_of(len(code))
    bpc = addr_of(len(code) + 2)
    emit(0x4C, spin & 0xFF, (spin >> 8) & 0xFF)  # JMP spin (absolute, safe)

    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'scpu_regprobe.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    print(f'Wrote {out}: {len(prg)} bytes')
    print('Scratch dump: VICE  ->  m c000 c009')
    print('Screen row0 ($0400): D0B0 D0B2 D0B3 D0B4 D0B5  (hex pairs)')
    print('Screen row1 ($0428): D0B6 D0B8 D0BC D07E D078  (hex pairs)')
    print('Expected (post-$D07E enable, spec): D0B0=$40, D0B2=$80, D0BC b7=0')


if __name__ == '__main__':
    sys.exit(main() or 0)
