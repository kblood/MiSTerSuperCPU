"""Test whether `bank ram00` poke bypasses IO side effects in xscpu64.

Hypothesis: writing to $D078/$D07E via `bank cpu > $D078 xx` triggers
SuperCPU register effects. Writing to the same address via
`bank ram00 > $D078 xx` should write bare RAM/SRAM only, no side effects.
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

BOOT_ADDR = 0x0800
BOOTSTRAP = bytes([0x78, 0x18, 0xFB, 0x5C, 0x00, 0x00, 0x20])


def main():
    SNAPSHOT = pathlib.Path(REPO / "tools" / "vice_oracle" / "postloader_bank00.bin").read_bytes()

    v = ViceOracle(vice_exe=VICE_EXE_DEFAULT)
    try:
        v.launch()
        v._cmd("reset 0", timeout=10.0)

        # Switch to bank ram00 for the snapshot load — bypasses IO and
        # ROM mapping. Then write the entire 64KB.
        print("STAGE: bank ram00 + load 64KB snapshot (skip $0800-$0806)")
        v._cmd("bank ram00", timeout=5.0)
        # Manually do the chunked writes since load_bytes_direct treats
        # bank=0 as "no switch".
        chunk = 64
        # Skip just bootstrap region (no need to skip IO/zp under ram00).
        regions = [(0x0000, BOOT_ADDR), (BOOT_ADDR + len(BOOTSTRAP), 0x10000)]
        t0 = time.time()
        for start, end in regions:
            i = start
            while i < end:
                piece = SNAPSHOT[i:min(i + chunk, end)]
                byte_str = " ".join(f"{b:02x}" for b in piece)
                v._cmd(f"> ${i:04x} {byte_str}", timeout=5.0, min_idle=0.05)
                i += chunk
        t1 = time.time()
        print(f"  load took {t1-t0:.1f}s")
        v._cmd("bank cpu", timeout=5.0)

        # Read back $0801 (snapshot byte) and $D078 (SCPU register)
        m_0801 = v.mem(0x0801, 1)
        m_d078 = v.mem(0xD078, 1)
        print(f"  $0801 (snapshot byte $b0): {m_0801.hex()}")
        print(f"  $D078 (snapshot value)    : {m_d078.hex()}")

        # Now do bootstrap via default bank cpu
        print("STAGE: bootstrap via bank cpu")
        v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)
        m_boot = v.mem(BOOT_ADDR, 7)
        print(f"  $0800..$0806 = {m_boot.hex(' ')}")

        # Run the bootstrap sequence and check whether VICE executes
        # SEI/CLC/XCE properly (no BRK divergence).
        print("STAGE: BP + g + 3 z steps")
        bp = v.set_breakpoint(BOOT_ADDR)
        v._sock.sendall(f"g ${BOOT_ADDR:04x}\r\n".encode())
        v._sock.settimeout(0.5)
        end = time.time() + 30.0
        buf = b""
        from vice_oracle import PROMPT
        seen = False
        while time.time() < end:
            try:
                ch = v._sock.recv(65536)
            except Exception:
                continue
            if not ch:
                break
            buf += ch
            if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                seen = True
                break
        print(f"  BP fired: {seen}")
        for i in range(3):
            v._cmd("z", timeout=5.0, min_idle=0.05)
            r = v._regs_fast()
            print(f"  z[{i}]: PC=${r['pc']:04x} P=${r['p']:02x} SP=${r['sp']:04x}")
        v.delete_breakpoint(bp)
        return 0
    finally:
        v.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
