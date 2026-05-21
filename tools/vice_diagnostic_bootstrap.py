"""Diagnostic: load bank $00 snapshot + bootstrap into VICE, read back $0800.

Repro path for the test_doom_bank20_diff harness's mystery: VICE runs $00
(BRK) at $0800 instead of our $78 (SEI). This script reproduces just the
poke phase and reads back the bytes immediately, so we can tell whether
the issue is in the poke or in a later step (e.g., reset/run side effect).
"""
from __future__ import annotations

import pathlib
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # type: ignore

SNAPSHOT = REPO / "tools" / "vice_oracle" / "postloader_bank00.bin"
BOOT_ADDR = 0x0800
BOOTSTRAP = bytes([0x78, 0x18, 0xFB, 0x5C, 0x00, 0x00, 0x20])


def main() -> int:
    snap = SNAPSHOT.read_bytes()
    print(f"Snapshot loaded: {len(snap)} bytes")
    print(f"  snapshot[$0800..$080F] = {snap[0x0800:0x0810].hex(' ')}")

    v = ViceOracle(vice_exe=VICE_EXE_DEFAULT)
    try:
        v.launch()
        print("VICE up; sending reset 0")
        v._cmd("reset 0", timeout=10.0)

        # Step 1: read $0800 BEFORE any pokes (post-reset baseline)
        m0 = v.mem(BOOT_ADDR, 16)
        print(f"After reset: $0800 = {m0.hex(' ')}")

        # Step 2: load snapshot in two halves around bootstrap
        t0 = time.time()
        v.load_bytes_direct(0x0000, snap[:BOOT_ADDR])
        v.load_bytes_direct(BOOT_ADDR + len(BOOTSTRAP),
                            snap[BOOT_ADDR + len(BOOTSTRAP):])
        t1 = time.time()
        print(f"Snapshot poke (split): {t1-t0:.1f}s")

        # Step 3: read $0800 BEFORE bootstrap (should still be reset value
        # since we skipped this region)
        m1 = v.mem(BOOT_ADDR, 16)
        print(f"After snapshot (skipped boot region): $0800 = {m1.hex(' ')}")

        # Step 4: load bootstrap
        v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)
        m2 = v.mem(BOOT_ADDR, 16)
        print(f"After bootstrap poke:                  $0800 = {m2.hex(' ')}")

        ok = m2[:7] == BOOTSTRAP
        print(f"Bootstrap match? {ok}")
        if not ok:
            print(f"  expected: {BOOTSTRAP.hex(' ')}")
            print(f"  got:      {m2[:7].hex(' ')}")
        return 0 if ok else 1
    finally:
        v.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
