#!/usr/bin/env python3
"""Build tools/test_rep_bram.prg.

PRG layout:
  $0801  BASIC stub: `10 SYS 2061` (tokenized)
  $080D  ML entry (SYS 2061 jumps here)
    SEI           ; lock out interrupts
    CLC
    XCE           ; -> native
    LDA #$00
    STA $0500
    STA $0501     ; pre-clear result bytes (emulation 8-bit STA)
    REP #$30      ; <-- the instruction under test
    LDA #$AABB    ; 16-bit immediate (3 bytes) if M=0
    STA $0500     ; 16-bit STA writes $BB,$AA if M=0
    SEP #$30
    XCE           ; back to emulation
    CLI
    RTS           ; return to BASIC

After RTS:
  PASS (M cleared): $0500=$BB (187), $0501=$AA (170)
  FAIL (M stuck):   $0500=$BB (187), $0501=$00 (0)

Host test reads results via `PRINT PEEK(1280);PEEK(1281)` after the prg runs.
"""
import struct
import os


def basic_stub(ml_addr: int) -> bytes:
    """Return tokenized BASIC `10 SYS <ml_addr>` line + terminator."""
    sys_token = b"\x9E"
    # No space after SYS token (matches bank20_peek.prg encoding).
    line_body = str(ml_addr).encode("ascii") + b"\x00"
    line_len = 2 + 2 + 1 + len(line_body)  # next_ptr(2)+linenum(2)+SYS+body
    next_ptr = 0x0801 + line_len
    return (
        struct.pack("<HH", next_ptr, 10)
        + sys_token
        + line_body
        + b"\x00\x00"  # end-of-program pointer
    )


def build_prg() -> bytes:
    load_addr = 0x0801
    # Build BASIC stub first so we know its length
    stub = basic_stub(0x080D)  # we'll verify ml_addr equals load_addr+len(stub)
    ml_addr = load_addr + len(stub)
    assert ml_addr == 0x080D, f"ml_addr = ${ml_addr:04X}, expected $080D"

    code = bytes(
        [
            0x78,                    # SEI
            0x18,                    # CLC
            0xFB,                    # XCE             -> native
            0xE2, 0x30,              # SEP #$30        force M=X=1 (XCE bug wa)
            0xA9, 0x00,              # LDA #$00        (8-bit, safe)
            0x8D, 0x3C, 0x03,        # STA $033C       pre-clear (cass buf)
            0x8D, 0x3D, 0x03,        # STA $033D       pre-clear
            0xC2, 0x30,              # REP #$30        <-- instruction under test
            0xA9, 0xBB, 0xAA,        # LDA #$AABB      (16-bit if M=0)
            0x8D, 0x3C, 0x03,        # STA $033C
            0xE2, 0x30,              # SEP #$30
            0xFB,                    # XCE             -> emu
            0x58,                    # CLI
            0x60,                    # RTS
        ]
    )

    body = stub + code
    return struct.pack("<H", load_addr) + body


def main():
    prg = build_prg()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_rep_bram.prg")
    with open(out, "wb") as f:
        f.write(prg)
    print(f"wrote {out} ({len(prg)} bytes)")


if __name__ == "__main__":
    main()
