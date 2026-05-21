#!/usr/bin/env python3
"""End-to-end test of the bank20_peek.prg reader.

Workflow:
 1. Deploy rebuilt core (wipes SDRAM)
 2. Copy RBF to /media/fat/_Computer/C64.rbf (for MGL path)
 3. Trigger doom.mgl load via MiSTer_cmd (populates SDRAM bank $20)
 4. Wait for REU load to finish
 5. Upload bank20_peek.prg and inject via mbc load_rom
 6. SYS 2061 to run the reader (stores $20:$0010..$0023 to $033C..$034F)
 7. Type BASIC peek loop to PRINT values
 8. Screenshot for visual readout
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "C64_MiSTer/output_files/C64.rbf"
PRG = "tools/bank20_peek.prg"


def main():
    print("=== Step 1: Deploy core (wipes SDRAM) ===")
    rc = md.cmd_deploy([RBF])
    if rc:
        return rc
    time.sleep(3)

    print("\n=== Step 2: Copy RBF to _Computer path for MGL ===")
    md.ssh("cp /media/fat/_Test/C64.rbf /media/fat/_Computer/C64.rbf")

    print("\n=== Step 3: Trigger doom.mgl load via MiSTer_cmd ===")
    md.ssh("echo 'load_core /media/fat/_Computer/doom.mgl' > /dev/MiSTer_cmd")

    print("\n=== Step 4: Wait 20s for REU data transfer ===")
    time.sleep(20)

    print("\n=== Step 5: Upload and inject bank20_peek.prg ===")
    rc = md.cmd_load_prg([PRG])
    if rc:
        return rc
    time.sleep(3)

    print("\n=== Step 6: SYS 2061 to run reader ===")
    md.cmd_keys(["sys 2061\\r"])
    time.sleep(2)

    print("\n=== Step 7: BASIC peek loop ===")
    md.cmd_keys(["fori=0to19:?peek(828+i);:nexti\\r"])
    time.sleep(2)

    print("\n=== Step 8: Screenshot ===")
    md.cmd_screen(["bank20_peek_result.png"])
    print("\nDone. Inspect bank20_peek_result.png for the printed byte values.")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
