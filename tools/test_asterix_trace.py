#!/usr/bin/env python3
"""Load asterix MGL on SuperCPU core and dump the 128-entry trace ring
to identify who calls BASIC NEW post-load.

Trace reset on rising edge of bram_invalidate (start of PRG download), so
the trace should contain only post-load instructions if the freeze trigger
($0801 wipe = dbg_0801_cnt_r > 0) fires.

Single mtype batch:
  1. Read status byte at $DF20 (= peek(57120))
  2. Dump all 4 pages sequentially; output scrolls, last visible = most
     recent instructions.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/asterix_scpu_abs.mgl"


def ssh(cmd, timeout=10):
    out, err, rc = md.ssh(cmd, timeout=timeout)
    return out


def main():
    print("[1] Fresh MiSTer restart")
    ssh(f"kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)

    print("[2] Force FPGA reprogram")
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)

    print(f"[3] Trigger MGL: {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(18)  # reset + boot + PRG stream + auto-run

    md.cmd_screen(["trace_post_mgl.png"])

    print("[4] mtype batch: type BASIC trace dumper + RUN")
    # BASIC program: dump 4 pages × 32 entries × 4 bytes
    # Each line: PC_lo PC_hi PBR IR
    # Last 25 entries visible on screen (most recent)
    # Status byte first
    # 57119 = $DF1F, 57120 = $DF20, 57121 = $DF21
    prog_lines = [
        # First print status byte, then dump
        "'?peek(57120)'",
        "enter",
        "'10 forp=0to3:poke57119,p:fori=0to31:a=57121+i*4'",
        "enter",
        "'20 ?peek(a);peek(a+1);peek(a+2);peek(a+3):next:next'",
        "enter",
        "'run'",
        "enter",
    ]
    cmd = "python3 /tmp/mtype.py " + " ".join(prog_lines)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"  mtype rc={rc}")

    time.sleep(3)
    md.cmd_screen(["trace_dump.png"])

    print("[5] Done. Inspect:")
    print("  - trace_post_mgl.png (post-MGL state)")
    print("  - trace_dump.png     (trace buffer dump — last ~25 entries visible)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
