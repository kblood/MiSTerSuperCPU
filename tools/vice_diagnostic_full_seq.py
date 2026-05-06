"""Diagnostic: replay the full test_doom_bank20_diff harness load sequence,
checking bootstrap bytes at $0800 at every stage. Pinpoints which stage
clobbers VICE's bootstrap.
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

SNAPSHOT_PATH = REPO / "tools" / "vice_oracle" / "postloader_bank00.bin"
DOOM_REU = REPO / "doom.reu"
BOOT_ADDR = 0x0800
BOOTSTRAP = bytes([0x78, 0x18, 0xFB, 0x5C, 0x00, 0x00, 0x20])

EXTRA_BANKS = [
    (0x80, 0x4000),
    (0x2D, 0x2000),
    (0x2C, 0x10000),
    (0x87, 0x10000),
]
LOOP_PATCHES = [
    (0x20, 0x00F6, bytes([0x80, 0x00])),
    (0x20, 0x011F, bytes([0x80, 0x00])),
    (0x20, 0x096A, bytes([0x80, 0x00])),
    (0x20, 0x099C, bytes([0x80, 0x00])),
    (0x20, 0x03B0, bytes([0x80, 0x04])),
    (0x80, 0x006F, bytes([0x80, 0x00])),
    (0x80, 0x0082, bytes([0x80, 0x00])),
    (0x80, 0x0095, bytes([0x80, 0x00])),
]


def _peek(v, label):
    m = v.mem(BOOT_ADDR, 7)
    ok = m == BOOTSTRAP
    flag = "OK " if ok else "FAIL"
    print(f"  [{flag}] {label}: $0800..$0806 = {m.hex(' ')}")
    return ok


def _extract_bank(bank, length):
    length = min(length, 0x10000)
    with DOOM_REU.open("rb") as f:
        f.seek(bank * 0x10000)
        return f.read(length)


def main():
    snap = SNAPSHOT_PATH.read_bytes()

    v = ViceOracle(vice_exe=VICE_EXE_DEFAULT)
    try:
        v.launch()
        print("STAGE: reset 0")
        v._cmd("reset 0", timeout=10.0)

        print("STAGE: snapshot (split)")
        t0 = time.time()
        v.load_bytes_direct(0x0000, snap[:BOOT_ADDR])
        v.load_bytes_direct(BOOT_ADDR + len(BOOTSTRAP),
                            snap[BOOT_ADDR + len(BOOTSTRAP):])
        print(f"  ({time.time()-t0:.1f}s)")
        m = v.mem(BOOT_ADDR, 7)
        print(f"  $0800..$0806 = {m.hex(' ')} (expect zeros, region skipped)")

        print("STAGE: bootstrap")
        v.load_bytes_direct(BOOT_ADDR, BOOTSTRAP)
        if not _peek(v, "after bootstrap"):
            return 1

        print("STAGE: bank $20 prologue")
        bank20 = _extract_bank(0x20, 0x1000)
        v.load_bytes_direct(0x200000, bank20)
        if not _peek(v, "after bank $20"):
            return 1

        for bank, length in EXTRA_BANKS:
            print(f"STAGE: extra bank ${bank:02x}")
            data = _extract_bank(bank, length)
            v.load_bytes_direct(bank << 16, data)
            if not _peek(v, f"after bank ${bank:02x}"):
                return 1

        print("STAGE: loop patches")
        for bank, addr, repl in LOOP_PATCHES:
            v.load_bytes_direct((bank << 16) | addr, repl)
        if not _peek(v, "after patches"):
            return 1

        # New: replay capture_trace_stepwise's setup steps and check
        # bootstrap bytes again at each transition.
        print("STAGE: set_breakpoint")
        bp = v.set_breakpoint(BOOT_ADDR)
        _peek(v, f"after BP #{bp}")

        print("STAGE: g $0800 (resume; expect BP to fire immediately)")
        import socket
        v._sock.sendall(f"g ${BOOT_ADDR:04x}\r\n".encode())
        v._sock.settimeout(0.5)
        import time as _t
        end = _t.time() + 30.0
        buf = b""
        from vice_oracle import PROMPT  # type: ignore
        seen_break = False
        while _t.time() < end:
            try:
                ch = v._sock.recv(65536)
            except socket.timeout:
                continue
            if not ch:
                break
            buf += ch
            if PROMPT in buf and (b"BREAK" in buf or b"Stop" in buf):
                seen_break = True
                break
        print(f"  BP fired: {seen_break}")
        _peek(v, "after BP fire")

        # mask_irq's r p=$NN
        print("STAGE: mask_irq (r p=$NN)")
        cur = v._regs_fast()
        new_p = cur["p"] | 0x04
        v._cmd(f"r p=${new_p:02x}", timeout=5.0, min_idle=0.05)
        _peek(v, "after mask_irq")

        print("STAGE: first z step")
        v._cmd("z", timeout=5.0, min_idle=0.05)
        m = v.mem(BOOT_ADDR, 7)
        regs = v._regs_fast()
        print(f"  $0800..$0806 = {m.hex(' ')}")
        print(f"  PC=${regs['pc']:04x} P=${regs['p']:02x} SP=${regs['sp']:04x}")

        print("STAGE: second z step")
        v._cmd("z", timeout=5.0, min_idle=0.05)
        m = v.mem(BOOT_ADDR, 7)
        regs = v._regs_fast()
        print(f"  $0800..$0806 = {m.hex(' ')}")
        print(f"  PC=${regs['pc']:04x} P=${regs['p']:02x} SP=${regs['sp']:04x}")

        v.delete_breakpoint(bp)
        return 0
    finally:
        v.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
