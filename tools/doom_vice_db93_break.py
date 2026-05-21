#!/usr/bin/env python3
"""VICE: break at $41:$DB93 (Doom's hardware-hang PC) and capture state.

Goal: discover whether VICE EVER hits $41:$DB93, and if so what X holds.
This determines what byte $00:$0707+X the wait is actually polling.

If VICE hits $41:$DB93 with X=$AF (or close), then the wait is on the
same byte hardware sees — and we just need to find what writes it.
If VICE hits with a different X, we've been chasing the wrong byte.
If VICE never hits this PC, hardware is on a divergent code path.
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
OUT_DIR = TOOLS / "doom_vice_db93_break"
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


def safe(line):
    return line.encode("ascii", errors="replace").decode("ascii")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

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
    print("Launching xscpu64 to break at $41:$DB93")

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
    print(safe("monitor connected"))
    expect_prompt(s, timeout=5.0)

    # 16-bit breakpoint at $DB93 — fires on any PB; we filter by PB after.
    out1 = cmd(s, "break db93", timeout=5.0)
    print(safe(f"break db93 -> {out1[-200:]}"))

    # Resume up to 90s, capturing every break
    print(safe("Resuming for up to 90s..."))
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    captures = []
    end_t = time.time() + 90.0
    buf = b""
    last_print = time.time()

    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except (socket.timeout, OSError):
            if time.time() - last_print > 10.0:
                elapsed = 90.0 - (end_t - time.time())
                print(safe(f"  t={elapsed:.0f}s breaks={len(captures)}"))
                last_print = time.time()
            continue
        if not ch: break
        buf += ch
        # Look for break-hit indicator
        text = buf.decode(errors="replace")
        if "Stop on" in text and ("(C:$" in text or "(R:$" in text):
            # Capture regs and a peek of $0700-$07FF
            captures.append(text)
            print(safe(f"\n[BREAK #{len(captures)}]"))
            print(safe(text[-400:]))
            buf = b""
            # Read regs explicitly
            regs = cmd(s, "r", timeout=3.0)
            print(safe(f"regs: {regs[-300:]}"))
            mem_07b0 = cmd(s, "m 07b0 07c0", timeout=3.0)
            print(safe(f"mem $07B0-$07C0: {mem_07b0[-150:]}"))
            captures[-1] += "\n" + regs + "\n" + mem_07b0
            # Resume
            s.sendall(b"x\r\n")
            s.settimeout(2.0)
            if len(captures) >= 5:
                print(safe("Got 5 breaks, stopping"))
                break

    print(safe(f"\nTotal breaks captured: {len(captures)}"))

    # Save
    out_path = OUT_DIR / "captures.txt"
    with open(out_path, "w", errors="replace") as f:
        f.write(f"VICE break at $41:$DB93 captures (90s window)\n")
        f.write("=" * 60 + "\n")
        for i, cap in enumerate(captures):
            f.write(f"\n--- BREAK #{i+1} ---\n")
            f.write(cap)
    print(safe(f"Saved -> {out_path}"))

    try: s.sendall(b"quit\r\n"); s.close()
    except OSError: pass
    time.sleep(1)
    try: p.terminate()
    except Exception: pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
