#!/usr/bin/env python3
"""Build cross_bank_write_test.prg — tests SCPU long-store from PBR != $00.

Hand-assembled 65C816 native-mode test. PRG loads at $0801 with a BASIC
stub `0 SYS 2061` so mbc's auto-RUN executes the ML directly.

After RUN:
- Screen $0400=$BB, $0401=$CC → long-store from PBR=$80 to $00:$xxxx WORKS
- Screen $0400=$00, $0401=$00 → long-store FAILS (writes never reached SDRAM)
- $0400=$77, $0401=$77 → handler never returned (JML to $80:$0000 wedged)
- $0402=$BB, $0403=$CC always (visual cue printed after return)

PEEK targets:
- PEEK 49664 ($C200) = readback target 1 (expect $BB)
- PEEK 49665 ($C201) = readback target 2 (expect $CC)
- PEEK 49666 ($C202) = $99 tripwire — proves baseline+pre-JML ran
- PEEK 49667 ($C203) = $AA tripwire — proves return-from-handler ran
"""
import os, struct, sys

def main():
    # PRG layout:
    # $0801: BASIC stub "0 SYS 2061" (12 bytes), ends at $080C
    # $080D: ML code (mirrors what used to live at $C000)
    # $0900: handler template (plant target = $80:$0000)
    code = bytearray()

    # ---- BASIC stub at $0801: "0 SYS 2061" + EOL + EOP -------------------
    # $0801: $0B $08 next-line ptr → $080B
    # $0803: $00 $00 line number 0
    # $0805: $9E SYS token
    # $0806-$0809: "2061" (ASCII)
    # $080A: $00 EOL
    # $080B: $00 $00 EOP
    # $080D: ML entry
    stub = bytes([
        0x0B,0x08,         # next-line ptr
        0x00,0x00,         # line number 0
        0x9E,              # SYS token
        0x32,0x30,0x36,0x31, # "2061"
        0x00,              # EOL
        0x00,0x00,         # EOP
    ])
    code += stub

    # current "virtual PC" relative to load addr $0801:
    # len(stub) = 12, so pos=12 corresponds to $080D
    def addr_of(offs):
        return 0x0801 + offs

    main_entry = 0x0801 + len(code)
    assert main_entry == 0x080D, f'main_entry={main_entry:#06x} != $080D'

    def emit(*bs):
        code.extend(bs)

    # SEI; CLC; XCE -> native
    emit(0x78)
    emit(0x18)
    emit(0xFB)
    # REP #$10  (X=16-bit, M=8-bit per native default after XCE from emu)
    emit(0xC2, 0x10)
    # LDX #$0000
    emit(0xA2, 0x00, 0x00)
    plant_loop_addr = addr_of(len(code))
    # LDA $00C100,X long-indexed — but our handler is now at $0900, planted from there
    # We'll plant from $0900 (relative to $0801) → at run time absolute addr.
    # Actually we plant via long-indexed LDA $00xxxx,X so we need a 24-bit operand.
    # Choose handler_template start = $0901 (after EOP-gap fill).
    # Source byte at $00:HANDLER_ADDR+X. STA $800000,X (long-indexed) → $80:0000+X.
    # We'll compute HANDLER_ADDR later; place a relocation marker.
    handler_addr_lo_offs = len(code) + 1  # second byte of LDA-long operand
    emit(0xBF, 0x00, 0x09, 0x00)  # LDA $000900,X — patched below if handler moves
    emit(0x9F, 0x00, 0x00, 0x80)  # STA $800000,X
    emit(0xE8)                    # INX
    emit(0xE0, 0x10, 0x00)        # CPX #$0010
    # BNE plant_loop  — relative branch back -14 from next-PC
    branch_target = plant_loop_addr
    branch_pc = 0x0801 + len(code) + 2  # after the BNE
    rel = branch_target - branch_pc
    assert -128 <= rel <= 127, f'plant branch rel={rel} out of range'
    emit(0xD0, rel & 0xFF)
    # SEP #$10 X=8-bit
    emit(0xE2, 0x10)
    # Baseline + tripwires
    emit(0xA9, 0x77)              # LDA #$77
    emit(0x8D, 0x00, 0xC2)        # STA $C200
    emit(0x8D, 0x01, 0xC2)        # STA $C201
    emit(0xA9, 0x99)              # LDA #$99
    emit(0x8D, 0x02, 0xC2)        # STA $C202 — pre-JML tripwire
    # JML $80:$0000
    emit(0x5C, 0x00, 0x00, 0x80)

    # gap until return_from_handler at $0840 (offset 0x3F from $0801)
    while len(code) < 0x3F:
        emit(0xEA)

    ret_addr = addr_of(len(code))
    # return_from_handler:
    emit(0xE2, 0x10)              # SEP #$10
    emit(0x38)                    # SEC
    emit(0xFB)                    # XCE -> emu
    emit(0x58)                    # CLI
    emit(0xA9, 0xAA)              # LDA #$AA
    emit(0x8D, 0x03, 0xC2)        # STA $C203 — post-handler tripwire
    emit(0xAD, 0x00, 0xC2)        # LDA $C200
    emit(0x8D, 0x00, 0x04)        # STA $0400
    emit(0xAD, 0x01, 0xC2)        # LDA $C201
    emit(0x8D, 0x01, 0x04)        # STA $0401
    emit(0xA9, 0xBB)              # LDA #$BB
    emit(0x8D, 0x02, 0x04)        # STA $0402 (visual cue: literal $BB)
    emit(0xA9, 0xCC)              # LDA #$CC
    emit(0x8D, 0x03, 0x04)        # STA $0403 (visual cue: literal $CC)
    emit(0x60)                    # RTS

    # pad until handler_template at offset $00FF (so $0900)
    while len(code) < 0xFF:
        emit(0xEA)

    handler_addr = addr_of(len(code))
    assert handler_addr == 0x0900, f'handler at {handler_addr:#06x}, expected $0900'
    # handler_template (executed at $80:$0000+X after plant_loop copies 16 bytes):
    emit(0xA9, 0xBB)              # LDA #$BB
    emit(0x8F, 0x00, 0xC2, 0x00)  # STA $00C200 long
    emit(0xA9, 0xCC)              # LDA #$CC
    emit(0x8F, 0x01, 0xC2, 0x00)  # STA $00C201 long
    # JML $00:ret_addr
    emit(0x5C, ret_addr & 0xFF, (ret_addr >> 8) & 0xFF, 0x00)
    # pad to 16 bytes
    while len(code) < 0xFF + 16:
        emit(0xEA)

    # Patch LDA-long source to point at $00:$0900 if we moved it (currently $0900)
    # operand at handler_addr_lo_offs..+2 = lo,hi,bank (24-bit little-endian)
    code[handler_addr_lo_offs+0] = handler_addr & 0xFF
    code[handler_addr_lo_offs+1] = (handler_addr >> 8) & 0xFF
    code[handler_addr_lo_offs+2] = 0x00

    # PRG = load_addr + body
    prg = struct.pack('<H', 0x0801) + bytes(code)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cross_bank_write_test.prg')
    with open(out, 'wb') as f:
        f.write(prg)
    end_addr = 0x0801 + len(code) - 1
    print(f'Wrote {out}: {len(prg)} bytes ($0801..${end_addr:04X})')
    print(f'  main_entry=${main_entry:04X}, ret=${ret_addr:04X}, handler=${handler_addr:04X}')

if __name__ == '__main__':
    sys.exit(main() or 0)
