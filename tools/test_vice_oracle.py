#!/usr/bin/env python3
"""Layer 2 validation — ViceOracle smoke test.

Pokes a tiny native-mode 65816 program into VICE xscpu64, single-steps
through it, and checks that A=$1234, X=$0056, PC=$080B at the spin.

Program at $0800:
    18         CLC
    FB         XCE              ; switch to native mode
    C2 30      REP #$30         ; M=0, X=0 (16-bit accumulator and index)
    A9 34 12   LDA #$1234
    A2 56 00   LDX #$0056
    4C 0B 08   JMP $080B        ; spin (PC sits at $080B)

Reset vector at $FFFC patched to $0800.

Pass -> print LAYER_2_OK, exit 0.
Fail -> print LAYER_2_FAIL with diagnostic, exit 1.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from vice_oracle import ViceOracle  # noqa: E402


PROGRAM = bytes([
    0x18,                    # CLC
    0xFB,                    # XCE
    0xC2, 0x30,              # REP #$30
    0xA9, 0x34, 0x12,        # LDA #$1234
    0xA2, 0x56, 0x00,        # LDX #$0056
    0x4C, 0x0B, 0x08,        # JMP $080B  (spin)
])

PROGRAM_ADDR = 0x0800
SPIN_PC      = 0x080B
RESET_VEC    = 0xFFFC


def _hex_dump(b: bytes) -> str:
    return " ".join(f"{x:02x}" for x in b)


def main() -> int:
    try:
        with ViceOracle() as v:
            # Show initial state
            r0 = v.regs()
            print(f"  initial: pc=${r0['pc']:04x} pbr=${r0['pbr']:02x}")

            # 1. Hard reset to a known state, then break execution.
            v._cmd("reset 0", timeout=10.0)

            # 2. Poke program at $0800
            print("  poking program ...")
            v.load_bytes_direct(PROGRAM_ADDR, PROGRAM)

            # Verify program landed
            mem_back = v.mem(PROGRAM_ADDR, len(PROGRAM))
            if mem_back != PROGRAM:
                print("LAYER_2_FAIL — program readback mismatch")
                print(f"  wrote: {_hex_dump(PROGRAM)}")
                print(f"  read:  {_hex_dump(mem_back)}")
                return 1

            # 3. Run from $0800 until we hit the spin loop at $080B.
            #    Setting reset vector at $FFFC doesn't work — that
            #    address is KERNAL ROM and writes go to underlying RAM
            #    that's invisible to the CPU. We use ViceOracle.run_to
            #    with start_pc to issue `g $0800` directly.
            print(f"  running to ${SPIN_PC:04x} ...")
            v.run_to(SPIN_PC, pbr=0, timeout=10.0, start_pc=PROGRAM_ADDR)

            r = v.regs()

            ok = (
                r["pc"]  == SPIN_PC and
                r["a"]   == 0x1234 and
                r["x"]   == 0x0056 and
                r["pbr"] == 0x00
            )
            if not ok:
                print("LAYER_2_FAIL — register check failed")
                print(f"  expected: pc=${SPIN_PC:04x} a=$1234 x=$0056 pbr=$00")
                print(f"  got:      pc=${r['pc']:04x} a=${r['a']:04x} "
                      f"x=${r['x']:04x} pbr=${r['pbr']:02x}")
                print(f"  full regs: {r}")
                return 1

            print("LAYER_2_OK")
            print(f"  regs: pc=${r['pc']:04x} a=${r['a']:04x} "
                  f"x=${r['x']:04x} y=${r['y']:04x} sp=${r['sp']:04x} "
                  f"pbr=${r['pbr']:02x} p=${r['p']:02x}")
            return 0

    except Exception as e:
        print(f"LAYER_2_FAIL — exception: {e}")
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
