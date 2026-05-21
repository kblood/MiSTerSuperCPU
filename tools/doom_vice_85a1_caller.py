#!/usr/bin/env python3
"""VICE: capture caller of $2C:$85A1 (music-error chain entry).

On hardware Doom halts at $2C:$A95C via:
  $2C:$85A1 -> $85B6 -> $85E8 -> $85F6 -> $A95C  (music-error chain)
This chain runs WITHOUT any JML[$74] dispatch (verified by writer trace
2026-05-07: $0074-$0076 is a JML scratchpad rewritten ~565 times/sec by
100+ writers; HW never reaches any of them before the halt).

VICE *also* eventually runs through this chain (or near it) — but
reaches gameplay (PB=$2A PC=$55A1) instead of the trap, presumably
because music_num is valid on VICE but $FFF7 (=-9) on HW.

This tool sets a breakpoint on $2C:$85A1, runs xscpu64 (NO -warp), and
when the BP fires:
  - dumps regs (PBR:PC, A, X, Y, P, SP)
  - dumps $0090-$0091 (music_num)
  - dumps stack top 16 bytes (return-PC of JSR/JSL caller)
  - dumps zero page so we can compare HW
  - chis 64 (last 64 instructions)

Output identifies WHO calls $2C:$85A1 on VICE and the value of
music_num at that moment. If VICE shows a valid music_num while HW
gives $FFF7, the divergence point is upstream — in whatever sets up
$0090-$0091 BEFORE the call into $85A1.
"""
from __future__ import annotations

import argparse
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
OUT_DIR = TOOLS / "doom_vice_85a1_caller"
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
        if not ch:
            break
        buf += ch
    return buf


def cmd(s, line, timeout=10.0):
    s.sendall((line.rstrip() + "\r\n").encode())
    return expect_prompt(s, timeout=timeout).decode(errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=180.0)
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--bp", type=str, default="2c:85a1",
                    help="break PC (default 2c:85a1 = music-error chain entry)")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    vice_args = [
        args.vice,
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",
        "-autostart", str(LOADER_PRG),
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{PORT}",
        "+sound",
        "-silent",
    ]
    print(f"Launching xscpu64 (NO warp), BP={args.bp}")

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

    # 65816 break: bank:addr form. VICE accepts "break <bank>:<addr>"
    bp_out = cmd(s, f"break {args.bp}", timeout=5.0)
    print(f"BP setup: {bp_out.strip()[-180:]}")

    raw_path = OUT_DIR / "raw.txt"
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write("--- bp setup ---\n" + bp_out)

    # Resume; wait until BP fires (we'll know via prompt change or HIT line)
    print(f"Resuming for up to {args.secs}s real-time ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    end_t = time.time() + args.secs
    buf = b""
    bp_fired = False
    last_print = time.time()

    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except (socket.timeout, OSError):
            if time.time() - last_print > 10.0:
                elapsed = args.secs - (end_t - time.time())
                print(f"  t={elapsed:.0f}s waiting for BP at {args.bp} ...")
                last_print = time.time()
            continue
        if not ch:
            break
        buf += ch
        text_chunk = ch.decode(errors='replace')
        raw_f.write(text_chunk); raw_f.flush()
        # Look for "Stop on" or BP-hit marker
        text = buf.decode(errors='replace').lower()
        if ("stop on exec" in text) or ("breakpoint" in text and args.bp.lower() in text):
            print(f"\nBP FIRED at {args.bp}")
            bp_fired = True
            break

    if not bp_fired:
        print(f"\nBP did NOT fire within {args.secs}s — caller may take longer "
              f"or VICE never reaches {args.bp}")
        # Pause anyway so we can still inspect state
        s.sendall(b"\r\n")
        time.sleep(0.5)

    # Drain any remaining output
    s.settimeout(0.5)
    try:
        while True:
            ch = s.recv(65536)
            if not ch: break
    except (socket.timeout, OSError):
        pass

    # Capture state
    print("\nCapturing state ...")
    regs = cmd(s, "r", timeout=5.0)
    print(f"r: {regs.strip()[-200:]}")
    raw_f.write("\n--- regs ---\n" + regs)

    mem_90 = cmd(s, "m $0090 $0091", timeout=5.0)
    raw_f.write("\n--- $0090-$0091 ---\n" + mem_90)
    print(f"$0090-$0091: {mem_90.strip()[-150:]}")

    mem_74 = cmd(s, "m $0074 $0076", timeout=5.0)
    raw_f.write("\n--- $0074-$0076 ---\n" + mem_74)
    print(f"$0074-$0076: {mem_74.strip()[-150:]}")

    # Dump stack top (SP+1 to SP+16) — JSL caller's return-PC sits here
    stk = cmd(s, "m $01e0 $01ff", timeout=5.0)
    raw_f.write("\n--- stack $01e0-$01ff ---\n" + stk)
    print(f"stack $01e0-$01ff:\n{stk.strip()[-400:]}")

    # CPU history — last 64 instructions including the call into $85a1
    chis = cmd(s, "chis 64", timeout=10.0)
    raw_f.write("\n--- chis 64 ---\n" + chis)
    print(f"\nLast instructions (tail):\n{chis.strip()[-1500:]}")

    raw_f.close()

    print(f"\nRaw -> {raw_path}")

    try: s.sendall(b"quit\r\n"); s.close()
    except OSError: pass
    time.sleep(1)
    try: p.terminate()
    except Exception: pass
    return 0 if bp_fired else 2


if __name__ == '__main__':
    sys.exit(main())
