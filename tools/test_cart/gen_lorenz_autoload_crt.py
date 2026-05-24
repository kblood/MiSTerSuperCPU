#!/usr/bin/env python3
"""Generate `lorenz_autoload.crt` — self-contained CBM80 cart that does
LOAD"*",8,1 + RUN at boot. No keyboard input, no MiSTer PRG autostart
dependency.

Mechanism:
  - Payload is a small ML loader at $C000 (load_addr in PRG header).
  - At cart-boot: prg_to_crt.py bootstrap copies the ML to $C000 and
    JMPs in. The bootstrap already sets $01=$37, masks CIA2 NMI, and
    inits $D011/$D018.
  - Our ML:
      1. Calls JSR $FF8A (RESTOR) to reset KERNAL vectors.
      2. Calls JSR $FF81 (CINT) to initialize VIC + cursor.
      3. Configures CIA2 DDR + IEC pins.
      4. Copies a 15-byte BASIC stub `LOAD"*",8,1` to $0801.
      5. Sets TXTTAB/VARTAB/ARYTAB/STREND/MEMSIZ for BASIC.
      6. Pre-fills the keyboard buffer with `RUN\\r`.
      7. CLI + JMP $A474 (BASIC warm start). BASIC displays READY,
         drains the kbd buffer, sees `RUN\\r`, parses it from the
         screen line, executes RUN on our LOAD program.
      8. BASIC LOAD"*",8,1 reads disk's first file and chains.

Output: tools/test_cart/out/lorenz_autoload.crt (16 KB).
Use with an MGL that ALSO mounts the disk:
  <file type="s" index="0" path="/.../lorenz_disk1.d64"/>
  <file type="f" index="1" path="/.../lorenz_autoload.crt"/>
"""
import os
import sys
from prg_to_crt import make_boot_crt


def build_loader_prg():
    LOAD_ADDR = 0xC000

    # BASIC program: `0 LOAD"*",8,1`
    BASIC_PRG = bytes([
        0x0E, 0x08,                     # next_line_ptr = $080E
        0x00, 0x00,                     # line number 0
        0x93,                           # LOAD token
        0x22, 0x2A, 0x22,               # "*"
        0x2C, 0x38,                     # ,8
        0x2C, 0x31,                     # ,1
        0x00,                           # end of line
        0x00, 0x00,                     # end of program
    ])
    BASIC_PRG_LEN = len(BASIC_PRG)
    BASIC_END_ADDR = 0x0801 + BASIC_PRG_LEN  # $0810

    ml = bytearray()

    # JSR $FF8A (RESTOR — set KERNAL vectors)
    ml += bytes([0x20, 0x8A, 0xFF])
    # JSR $FF81 (CINT — init VIC, screen, cursor)
    ml += bytes([0x20, 0x81, 0xFF])

    # CIA2 DDR PA: bits 0-5 output, 6-7 input ($3F)
    ml += bytes([0xA9, 0x3F, 0x8D, 0x02, 0xDD])
    # CIA2 PA: VIC bank 0 (bits 0,1 = %11 inverted = bank 0 $0000-$3FFF)
    # and deassert IEC ATN/CLK/DATA (bits 3,4,5 high).
    ml += bytes([0xA9, 0x07, 0x8D, 0x00, 0xDD])

    # Copy BASIC_PRG from cart payload (basic_data label, set after the loop)
    # LDX #len-1 ; loop: LDA <basic>,X ; STA $0801,X ; DEX ; BPL loop
    ml += bytes([0xA2, BASIC_PRG_LEN - 1])
    loop_target = len(ml)                        # where LDA starts
    ml += bytes([0xBD, 0x00, 0x00])             # placeholder for LDA basic,X
    lda_abs_off = loop_target                    # for later patch
    ml += bytes([0x9D, 0x01, 0x08])             # STA $0801,X
    ml += bytes([0xCA])                          # DEX
    # BPL back to LDA basic,X (operand = target - (BPL_op_addr + 2))
    bpl_off = len(ml)
    disp = loop_target - (bpl_off + 2)
    assert -128 <= disp < 0, f"BPL disp out of range: {disp}"
    ml += bytes([0x10, disp & 0xFF])             # BPL loop_target

    # Set BASIC pointers.
    # TXTTAB ($2B-$2C) = $0801
    ml += bytes([0xA9, 0x01, 0x85, 0x2B])
    ml += bytes([0xA9, 0x08, 0x85, 0x2C])
    # VARTAB ($2D-$2E), ARYTAB ($2F-$30), STREND ($31-$32) = BASIC_END_ADDR
    end_lo = BASIC_END_ADDR & 0xFF
    end_hi = (BASIC_END_ADDR >> 8) & 0xFF
    ml += bytes([0xA9, end_lo, 0x85, 0x2D, 0x85, 0x2F, 0x85, 0x31])
    ml += bytes([0xA9, end_hi, 0x85, 0x2E, 0x85, 0x30, 0x85, 0x32])
    # MEMSIZ ($37-$38) = $A000
    ml += bytes([0xA9, 0x00, 0x85, 0x37])
    ml += bytes([0xA9, 0xA0, 0x85, 0x38])

    # Pre-fill keyboard buffer with "RUN\r"
    ml += bytes([0xA9, 0x52, 0x8D, 0x77, 0x02])  # R
    ml += bytes([0xA9, 0x55, 0x8D, 0x78, 0x02])  # U
    ml += bytes([0xA9, 0x4E, 0x8D, 0x79, 0x02])  # N
    ml += bytes([0xA9, 0x0D, 0x8D, 0x7A, 0x02])  # CR
    ml += bytes([0xA9, 0x04, 0x85, 0xC6])         # $C6 = 4

    # CLI then JMP $A474 (BASIC warm start)
    ml += bytes([0x58])
    ml += bytes([0x4C, 0x74, 0xA4])

    # BASIC PRG data appended
    basic_addr = LOAD_ADDR + len(ml)
    ml += BASIC_PRG

    # Patch the LDA absolute,X address
    ml[lda_abs_off + 1] = basic_addr & 0xFF
    ml[lda_abs_off + 2] = (basic_addr >> 8) & 0xFF

    # PRG file = 2-byte load_addr + payload
    prg = bytes([LOAD_ADDR & 0xFF, (LOAD_ADDR >> 8) & 0xFF]) + bytes(ml)
    return prg


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    prg_path = os.path.join(out_dir, "out", "lorenz_autoload_ml.prg")
    crt_path = os.path.join(out_dir, "out", "lorenz_autoload.crt")
    os.makedirs(os.path.dirname(prg_path), exist_ok=True)

    prg = build_loader_prg()
    with open(prg_path, "wb") as f:
        f.write(prg)
    print(f"ML loader PRG: {prg_path} ({len(prg)} bytes)")

    crt, info = make_boot_crt(prg, name="LORENZ_AL", entry_offset=0)
    with open(crt_path, "wb") as f:
        f.write(crt)
    print(f"CRT: {crt_path} ({len(crt)} bytes)")
    print(f"  load_addr  ${info['load_addr']:04X}")
    print(f"  entry      ${info['entry']:04X}")
    print(f"  payload    {info['payload_size']} bytes")
    print(f"  bootstrap  {info['bootstrap_size']} bytes")


if __name__ == "__main__":
    main()
