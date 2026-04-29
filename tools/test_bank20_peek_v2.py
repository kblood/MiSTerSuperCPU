#!/usr/bin/env python3
"""End-to-end bank $20 peek test using BASIC DATA+POKE+SYS (no mbc).

Avoids mbc load_rom entirely because mbc load_rom inject appears to
silently fail for REU-carrying MGLs. MGL-via-pipe handles the REU load
correctly (see project_mgl_pipe_loads_files.md).

Workflow:
 1. Deploy rebuilt core
 2. Copy RBF to _Computer path for MGL
 3. Trigger doom.mgl load via MiSTer_cmd (populates SDRAM bank $20)
 4. Type the BASIC DATA-loader program + RUN via mtype.py (one batch)
 5. Type BASIC peek loop to PRINT values
 6. Screenshot
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "C64_MiSTer/output_files/C64.rbf"
PRG = "tools/bank20_peek.prg"


def build_basic_lines():
    # Skip 2-byte load addr + 12-byte BASIC stub = 14 bytes of overhead
    code = open(PRG, 'rb').read()[14:]
    lines = []
    lines.append(f"10 fori=0to{len(code)-1}:readd:poke49152+i,d:next:sys49152")
    per = 16
    ln = 20
    for i in range(0, len(code), per):
        chunk = code[i:i+per]
        lines.append(f"{ln} data" + ",".join(str(b) for b in chunk))
        ln += 10
    return lines


def main():
    print("=== Step 1: Deploy core ===")
    if md.cmd_deploy([RBF]):
        return 1
    time.sleep(4)

    print("\n=== Step 2: Copy RBF to _Computer for MGL ===")
    md.ssh("cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf")

    print("\n=== Step 3: Load doom.mgl (transfers .reu into SDRAM) ===")
    md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")
    print("Waiting 20s for REU transfer...")
    time.sleep(20)

    print("\n=== Step 4: Type BASIC DATA loader (one line at a time) ===")
    lines = build_basic_lines()
    print(f"  {len(lines)} BASIC lines, code len 154 bytes")
    for i, line in enumerate(lines, 1):
        print(f"  [{i}/{len(lines)}] {line[:60]}")
        if not md.cmd_keys([line + "\\r"]):
            print(f"  LINE {i} FAILED")
            return 1
    print("  Running...")
    md.cmd_keys(["run\\r"])
    time.sleep(4)

    print("\n=== Step 5: Type BASIC PEEK loop ===")
    md.cmd_keys(["fori=0to19:?peek(828+i);:nexti\\r"])
    time.sleep(4)

    print("\n=== Step 6: Screenshot ===")
    md.cmd_screen(["bank20_peek_v2.png"])
    print("\nDone. See bank20_peek_v2.png")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
