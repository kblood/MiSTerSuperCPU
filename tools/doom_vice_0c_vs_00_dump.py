#!/usr/bin/env python3
"""VICE: explicit bank-disambiguated dump of $0700-$07FF.

Per discovery 2026-05-10:
  Prior `m $0700 $07ff` defaulted to PB=$0C (the current PBR), so the
  "JIT trampoline" memory we saw is at $0C:$0700-$07FF (SuperRAM), NOT
  $00:$0700-$07FF (motherboard RAM).

  The wait at $41:$DB93 uses `df 07 07 00 / b0 03 / d0 fe`
  = long CMP $00:$0707,X — reads bank $00 explicitly. So:
    - Trampoline code lives in $0C SRAM at $0700-$07FF
    - Trampoline INC absolute writes (DBR=$00) target $00:$07B6
    - Wait polls $00:$07B6 — same byte the INC writes ✓

This experiment pins down both banks unambiguously by using VICE's
banked memory commands (`bank cpu` / `bank ram`).

Output: `tools/doom_vice_0c_vs_00_dump/dumps.txt`
"""
from __future__ import annotations

import os
import pathlib
import socket
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"
OUT_DIR = TOOLS / "doom_vice_0c_vs_00_dump"
PORT = 6510


def expect_prompt(s, timeout=10.0):
    s.settimeout(2.0)
    buf = b""
    end = time.time() + timeout
    last_t = time.time()
    while time.time() < end:
        try:
            ch = s.recv(65536); last_t = time.time()
        except (socket.timeout, OSError):
            if (b"(C:$" in buf or b"(R:$" in buf) and (time.time() - last_t) > 0.3:
                return buf
            continue
        if not ch: break
        buf += ch
    return buf


def cmd(s, line, timeout=10.0):
    s.sendall((line.rstrip() + "\r\n").encode())
    return expect_prompt(s, timeout=timeout).decode(errors="replace")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    secs = 30.0  # Run Doom long enough for trampoline JIT to populate

    vice_args = [
        VICE_EXE_DEFAULT,
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",
        "-autostart", str(LOADER_PRG),
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{PORT}",
        "+sound",
        "-silent",
    ]
    print(f"Launching xscpu64, will pause after {secs}s and dump banks $00 and $0C")

    creationflags = 0
    if os.name == "nt":
        creationflags = getattr(subprocess, "DETACHED_PROCESS", 0)
    p = subprocess.Popen(vice_args, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL,
                         creationflags=creationflags)
    time.sleep(3)
    s = None
    for _ in range(30):
        try:
            s = socket.socket(); s.settimeout(2)
            s.connect(("127.0.0.1", PORT)); break
        except (socket.timeout, ConnectionRefusedError, OSError):
            s = None; time.sleep(1)
    if s is None:
        print("ERROR: cannot connect"); p.terminate(); return 1
    print("monitor connected")
    expect_prompt(s, timeout=5.0)

    # Resume and let Doom run
    print(f"Resuming for {secs}s real-time ...")
    s.sendall(b"x\r\n")
    time.sleep(secs)

    # Pause: send Ctrl-C equivalent (just a newline often re-prompts on resumed VICE)
    # In VICE remote monitor, sending a single newline doesn't pause. Use the explicit
    # break command if available, or just let the recv timeout and reconnect.
    # Simpler: send ENTER then wait for the prompt (VICE remote monitor "x" runs until
    # interrupted by another command — sending a regular command should re-pause).
    s.sendall(b"r\r\n")  # 'r' = registers; this re-enters prompt
    out = expect_prompt(s, timeout=10.0).decode(errors="replace")
    print("Regs at pause:")
    print(out[-400:])
    regs_text = out

    dumps = {}

    # Use VICE's banked dump syntax: 'm <bank> <addr> <addr>' may not work directly;
    # try the "bank" command first to switch context, then 'm'.
    # xscpu64 supports: `m cpu:0700 cpu:07ff` or just `m 0700 07ff` (current bank).
    # For the SuperCPU 24-bit space we can try the long-address form: `m 0c0700 0c07ff`.

    # Try long-address (24-bit) syntax first
    for tag, lo, hi in [
        ("00:0700-07FF", "000700", "0007ff"),
        ("0C:0700-07FF", "0c0700", "0c07ff"),
        ("00:07B0-07C0 detail", "0007b0", "0007c0"),
        ("0C:07B0-07C0 detail", "0c07b0", "0c07c0"),
        ("00:0790-07A0 (INC code site)", "000790", "0007a0"),
        ("0C:0790-07A0 (INC code site)", "0c0790", "0c07a0"),
    ]:
        out = cmd(s, f"m {lo} {hi}", timeout=5.0)
        dumps[tag] = out
        print(f"\n--- {tag} ---")
        for line in out.splitlines():
            safe = line.encode("ascii", errors="replace").decode("ascii")
            if safe.startswith(">") or (":" in safe[:8] and safe[:1] in "0123456789abcdefABCDEF>"):
                print(f"  {safe}")

    # Save full output
    out_path = OUT_DIR / "dumps.txt"
    with open(out_path, "w", errors="replace") as f:
        f.write("VICE banked memory dump after Doom run\n")
        f.write(f"Run length: {secs}s\n")
        f.write("=" * 60 + "\n\n")
        f.write("--- registers at pause ---\n")
        f.write(regs_text)
        f.write("\n")
        for tag, dump in dumps.items():
            f.write(f"--- {tag} ---\n")
            f.write(dump)
            f.write("\n")
    print(f"\nSaved -> {out_path}")

    try: s.sendall(b"quit\r\n"); s.close()
    except OSError: pass
    time.sleep(1)
    try: p.terminate()
    except Exception: pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
