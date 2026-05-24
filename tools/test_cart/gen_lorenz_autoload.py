#!/usr/bin/env python3
"""Generate `lorenz_autoload.prg` and `.crt` — keyboard-free LOAD+RUN.

The PRG is a single-line BASIC program at $0801:
    0 LOAD"*",8,1

When MiSTer's C64 core auto-RUNs the PRG (start_strk in c64.sv:1036),
BASIC executes LOAD"*",8,1 which loads the disk's first file at its
native address and chains BASIC to the new program. The new program
runs normally — the Lorenz STARTV215 file is itself a BASIC program
that SYS's into the test runner.

Two delivery forms produced:
  - lorenz_autoload.prg : load via MGL <file type="f" index="1">
                           or mbc load_rom. MiSTer auto-runs it.
  - lorenz_autoload.crt : 8K CBM80 cartridge (via prg_to_crt.py). Use
                           when PRG-injection is unavailable or you
                           want a truly self-contained boot path.

Use with:
  <mistergamedescription>
    <rbf>_Test/C64</rbf>
    <file delay="2" type="s" index="0" path="/media/fat/games/C64/lorenz_disk1.d64"/>
    <file delay="8" type="f" index="1" path="/.../lorenz_autoload.prg"/>
  </mistergamedescription>
"""
import os
import sys
import subprocess


def build_prg():
    # BASIC line 0: LOAD"*",8,1
    # Layout: load_addr | next_line_ptr | line# | tokens | $00 | $00 $00
    LOAD_ADDR = 0x0801
    tokens = bytes([
        0x93,                   # LOAD token
        0x22, 0x2A, 0x22,       # "*"
        0x2C, 0x38,             # ,8
        0x2C, 0x31,             # ,1
        0x00,                   # end of line
    ])
    # Line header: next_line_ptr (2) + line# (2)
    # next_line_ptr = address just past this line's terminator
    line_start = LOAD_ADDR
    header_size = 4
    next_line_addr = line_start + header_size + len(tokens)
    header = bytes([
        next_line_addr & 0xFF, (next_line_addr >> 8) & 0xFF,
        0x00, 0x00,             # line number 0
    ])
    # End of program: 2 zero bytes (null next-line ptr)
    end_marker = bytes([0x00, 0x00])

    prg = bytes([LOAD_ADDR & 0xFF, (LOAD_ADDR >> 8) & 0xFF]) + header + tokens + end_marker
    return prg


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    prg_path = os.path.join(out_dir, "out", "lorenz_autoload.prg")
    crt_path = os.path.join(out_dir, "out", "lorenz_autoload.crt")
    os.makedirs(os.path.dirname(prg_path), exist_ok=True)

    prg = build_prg()
    with open(prg_path, "wb") as f:
        f.write(prg)
    print(f"PRG: {prg_path} ({len(prg)} bytes)")
    print(f"  hexdump: {prg.hex(' ')}")

    # Wrap as CRT
    # Note: the BASIC program is tokenized data, not 6502 code. Direct CRT
    # boot would JMP into it = crash. The CRT path therefore needs a
    # different stub — see lorenz_autoload_crt.py for the ML version.
    # Here we just produce the PRG; the CRT requires the ML loader.
    print()
    print("PRG written. CRT requires the ML loader stub (see "
          "lorenz_autoload_crt.py).")


if __name__ == "__main__":
    main()
