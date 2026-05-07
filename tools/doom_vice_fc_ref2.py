#!/usr/bin/env python3
"""VICE reference v2 — skip watches, dump final state + CPU history.

The watch-store approach failed (0 events captured) because VICE 3.10
under -warp + remote-monitor doesn't fire watches the way naively
expected. This script takes a simpler path:

  1. Launch xscpu64 with REU + autostart loader.prg
  2. Warp for N seconds
  3. Pause back into monitor
  4. Dump $00:$00FC, $00:$0074-$76, current PBR:PC, regs
  5. Dump chis (CPU history) — last 256+ instructions
  6. Optionally: dump zero page + small slices of bank $00 around halt

Then compare to hardware Probe B values:
  HW: V=E8 E8 F6 0E (newest=0E), G=7D 07 00, WP=$2C:$8605, CY=23389
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"
OUT_DIR = TOOLS / "doom_vice_fc_ref"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warp-secs", type=float, default=180.0)
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--out", type=pathlib.Path, default=OUT_DIR)
    args = ap.parse_args()

    if not LOADER_PRG.exists() or not DOOM_REU.exists():
        print("ERROR: loader.prg or doom.reu missing", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)

    extra = [
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",
        "-autostart", str(LOADER_PRG),
        "+sound",
    ]

    print(f"Launching xscpu64 (warp, autostart {LOADER_PRG.name})")
    v = ViceOracle(vice_exe=args.vice)

    try:
        v.launch(extra_args=extra)
        print("Monitor connected; cpu paused at boot")

        # Resume execution under -warp without setting any breakpoint.
        # The monitor will sit idle while CPU runs in warp; we re-enter
        # by sending a bare CR after warp_secs.
        print(f"Resuming for {args.warp_secs}s warp wallclock ...")
        v._sock.sendall(b"x\r\n")
        time.sleep(args.warp_secs)

        # Force back into monitor
        print("Sending CR to pause back into monitor ...")
        v._sock.sendall(b"\r\n")
        time.sleep(0.5)
        v._drain(idle_s=0.5, max_s=3.0)

        # Dump current registers
        try:
            regs = v.regs()
            print(f"After warp: PBR=${regs['pbr']:02x} PC=${regs['pc']:04x} "
                  f"A=${regs['a']:04x} X=${regs['x']:04x} Y=${regs['y']:04x} "
                  f"SP=${regs['sp']:04x} P=${regs['p']:02x} E={regs['e']}")
        except Exception as e:
            print(f"regs() failed: {e}")
            regs = {}

        # Dump $00:$00FC..FE and $00:$0074..76
        mem_fc = v._cmd("m $00fc $00fe", timeout=5.0, min_idle=0.5)
        mem_74 = v._cmd("m $0074 $0076", timeout=5.0, min_idle=0.5)
        mem_zp = v._cmd("m $0000 $00ff", timeout=10.0, min_idle=0.5)
        print(f"\n$00:$00FC-$00FE: {mem_fc.strip()[-200:]}")
        print(f"$00:$0074-$0076: {mem_74.strip()[-200:]}")

        # Dump CPU history (chis = "show chist", last N instructions)
        chis_out = v._cmd("chis 64", timeout=10.0, min_idle=0.5)
        print(f"\nLast 64 instructions (chis):\n{chis_out.strip()[-2000:]}")

        # Save raw outputs
        with open(args.out / "raw_v2.txt", 'w', errors='replace') as f:
            f.write("=== regs ===\n")
            f.write(repr(regs) + "\n\n")
            f.write("=== $00FC-$00FE ===\n" + mem_fc + "\n")
            f.write("=== $0074-$0076 ===\n" + mem_74 + "\n")
            f.write("=== $0000-$00FF (zero page) ===\n" + mem_zp + "\n")
            f.write("=== chis 64 (last instructions) ===\n" + chis_out + "\n")

        print(f"\nRaw -> {args.out / 'raw_v2.txt'}")

        # Comparison summary
        print("\n=== HARDWARE PROBE B BASELINE ===")
        print("  WP = $2C:$8605  V = E8 E8 F6 0E  CY = 23389")
        print("  G  = $00:$077D  ($0074=$7D, $0075=$07, $0076=$00)")
        print("  PC at halt = $2C:$A95C  ('Bad music number -9' trap)")
        print("\n=== VICE REFERENCE (this run) ===")
        if regs:
            print(f"  PBR:PC = ${regs.get('pbr',0):02x}:${regs.get('pc',0):04x}")
        print(f"  $00:$00FC mem dump: {mem_fc.strip().splitlines()[-1] if mem_fc.strip() else '(empty)'}")
        print(f"  $00:$0074 mem dump: {mem_74.strip().splitlines()[-1] if mem_74.strip() else '(empty)'}")

    finally:
        v.shutdown()

    return 0


if __name__ == '__main__':
    sys.exit(main())
