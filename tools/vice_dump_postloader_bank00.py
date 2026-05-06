"""Dump VICE's post-loader bank $00 motherboard RAM as a binary snapshot.

The cocotb diff harness hits an architectural ceiling at JML $00:$0E0C
(in bank $2C entry code at $A792). Bank $00 motherboard RAM contains
post-loader content that the real Doom loader populates via REU FETCH
DMA at runtime. Without a snapshot of that content, the harness cannot
push past the JML.

This tool runs xscpu64 with REU + autostart loader.prg, lets the loader
do all its work, and dumps bank $00 ($0000..$FFFF) at the moment the
loader transfers to bank $20 game code (BP at PC=$0000, which only
occurs at the bank $20 native-mode entry — KERNAL/BASIC never execute
at PC=$0000).

Usage:
    python tools/vice_dump_postloader_bank00.py \\
        --out tools/vice_oracle/postloader_bank00.bin

Output: 65536-byte raw binary, indexable directly by the diff harness.
"""
from __future__ import annotations

import argparse
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, required=True,
                    help="output path for raw 65536-byte bank $00 snapshot")
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="seconds to wait for loader → bank $20 transition")
    args = ap.parse_args()

    if not LOADER_PRG.exists():
        print(f"ERROR: {LOADER_PRG} not found", file=sys.stderr)
        return 2
    if not DOOM_REU.exists():
        print(f"ERROR: {DOOM_REU} not found", file=sys.stderr)
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)

    # Flags mirror tools/doom_vice_chis.py which is known to run loader.prg
    # to steady state inside xscpu64+REU. Critical: -reusize 16384 sets REU
    # size to 16 MB (matches doom.reu). +reuimagerw makes the image r/w.
    extra = [
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",  # inject mode (fast)
        "-autostart", str(LOADER_PRG),
        "+sound",                  # disable sound for speed
    ]

    print(f"Launching xscpu64 with REU={DOOM_REU.name} autostart={LOADER_PRG.name}")
    t0 = time.time()
    v = ViceOracle(vice_exe=args.vice)
    try:
        v.launch(extra_args=extra)

        # The chis-tool pattern: don't try to BP — just exit monitor (`x`),
        # let warp-mode loader run for N seconds, then force pause. By
        # then loader has done all REU FETCHes and bank $20 game code is
        # in steady state. Bank $00 contents include all loader population.
        print(f"Resuming execution for {args.timeout}s of warp runtime…")
        v._sock.sendall(b"x\r\n")
        time.sleep(args.timeout)

        # Force monitor back in by sending \r\n
        v._sock.sendall(b"\r\n")
        time.sleep(0.5)
        v._drain(idle_s=0.5, max_s=3.0)

        wall = time.time() - t0
        regs = v.regs()
        print(f"After {wall:.1f}s wall: "
              f"PBR=${regs['pbr']:02x} PC=${regs['pc']:04x}")

        print("Dumping bank $00 ($0000..$FFFF)…")
        dump_t0 = time.time()
        bank0 = v.mem(0x0000, 0x10000)
        dump_t = time.time() - dump_t0
        print(f"Dumped {len(bank0)} bytes in {dump_t:.1f}s")
    finally:
        v.shutdown()

    args.out.write_bytes(bank0)
    nonzero = sum(1 for b in bank0 if b != 0)
    print(f"Wrote {args.out} ({len(bank0)} bytes; {nonzero} non-zero)")

    # Sanity probes
    print(f"  $0E0C..$0E1F: {bank0[0x0E0C:0x0E20].hex(' ')}")
    print(f"  $00FC..$00FF: {bank0[0x00FC:0x0100].hex(' ')}")
    print(f"  $0700..$070F: {bank0[0x0700:0x0710].hex(' ')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
