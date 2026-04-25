"""Drive the SDRAM peek register at $DF1D/$DF1E/$DF1F.

Usage:
    python tools/peek_addr.py <hex_addr> [seconds]
    python tools/peek_addr.py 00C003 30

Steps:
    1. POKE peek address registers via mtype (BASIC keyboard injection).
       - $DF1D = lo  (57117 decimal)
       - $DF1E = mid (57118 decimal)
       - $DF1F = hi  (57119 decimal)  -- this write triggers the readback
    2. Capture UART for `seconds` (default 15).
    3. Print all unique W:NNDD samples (NN=peek_seq, DD=peek_data).

Notes:
    - The peek auto-rearms after every capture so DD refreshes continuously.
    - NN advances => the io_cycle path is firing (peek IS reading SDRAM).
    - NN frozen => peek armed but never captured (something starves io_cycle).
    - W:0000 only => arm never landed (the BASIC POKE didn't run).

This tool depends on mister_debug.py for SSH/mtype helpers.
"""
from __future__ import annotations

import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent

W_RE = re.compile(r"W:([0-9A-Fa-f]{4})")


def usage_and_exit():
    print(__doc__)
    sys.exit(2)


def poke_arm(addr24: int) -> None:
    """Send the 3-POKE arm sequence via BASIC keystroke injection."""
    lo  = addr24 & 0xFF
    mid = (addr24 >> 8) & 0xFF
    hi  = (addr24 >> 16) & 0xFF
    line = f"POKE57117,{lo}:POKE57118,{mid}:POKE57119,{hi}\\r"
    print(f"[arm] $DF1D={lo:02X}  $DF1E={mid:02X}  $DF1F={hi:02X}  -> peek $%06X" % addr24)
    rc = subprocess.call([sys.executable, str(HERE / "mister_debug.py"), "keys", line])
    if rc != 0:
        print(f"[warn] mtype returned {rc}")


def capture_w_samples(seconds: int) -> str:
    """Run mister_debug.py uart for `seconds`, return the captured stdout."""
    print(f"[uart] capturing {seconds}s ...")
    res = subprocess.run(
        [sys.executable, str(HERE / "mister_debug.py"), "uart", str(seconds)],
        capture_output=True, text=True, timeout=seconds + 30,
    )
    return res.stdout or ""


def report(text: str) -> None:
    samples = W_RE.findall(text)
    if not samples:
        print("[result] No W: samples found in UART output.")
        print("[result] Check: is debug UART enabled? Did mtype reach BASIC?")
        return
    counter = Counter(s.upper() for s in samples)
    seqs = set()
    bytes_ = set()
    for s in counter:
        seqs.add(s[:2])
        bytes_.add(s[2:])
    print(f"[result] {len(samples)} W: samples  /  {len(counter)} unique values")
    print(f"[result] peek_seq distinct values: {len(seqs)}  (==1 => never advanced)")
    print(f"[result] peek_data distinct bytes: {sorted(bytes_)}")
    print("[result] top 10 W:NNDD frequencies:")
    for val, cnt in counter.most_common(10):
        nn, dd = val[:2], val[2:]
        print(f"          W:{nn}{dd}  count={cnt}")


def main(argv: list[str]) -> int:
    if len(argv) < 1:
        usage_and_exit()
    try:
        addr24 = int(argv[0], 16)
    except ValueError:
        usage_and_exit()
        return 2
    if not (0 <= addr24 <= 0xFFFFFF):
        print(f"[error] addr {addr24:X} out of range")
        return 2
    seconds = int(argv[1]) if len(argv) >= 2 else 15

    poke_arm(addr24)
    # Small settle delay so the BASIC line lands and the first capture rolls.
    time.sleep(2.0)
    text = capture_w_samples(seconds)
    report(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
