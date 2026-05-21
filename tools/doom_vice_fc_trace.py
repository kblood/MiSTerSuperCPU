#!/usr/bin/env python3
"""VICE $00:$00FC writer trace WITHOUT warp.

VICE watches don't fire when running in -warp + remote-monitor mode.
This script runs xscpu64 at native 1 MHz speed, sets a watch on
$00:$00FC stores, runs for N seconds, and captures every writer-PC.

Tradeoff: 1 MHz real-time = much slower, won't get through full 16 MB
loader. But will capture the FIRST several hundred-to-thousand writes,
showing which writers fire and in what order. Compare to hardware
Probe B output to identify writer-PC divergence.

HW Probe B baseline (full-loader v293):
  CY = 23389  WP = $2C:$8605  V = E8 E8 F6 0E  G = $00:$077D
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
from collections import Counter

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"
OUT_DIR = TOOLS / "doom_vice_fc_trace"
PORT = 6510

WATCH_HDR_RE = re.compile(r"#\d+\s*\(Stop on store at\s*\$([0-9a-fA-F]+)\)")
REG_LINE_RE = re.compile(
    r"\.;\s*([0-9a-fA-F]{2})\s+([0-9a-fA-F]{4})\s+"
    r"[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+"
)


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=120.0,
                    help="real-time seconds to capture (default 120s)")
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    args = ap.parse_args()

    if not LOADER_PRG.exists() or not DOOM_REU.exists():
        print("ERROR: loader.prg or doom.reu missing"); return 2
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # NOTE: NO -warp flag. We need watches to fire.
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
    print(f"Launching xscpu64 (NO warp) autostart={LOADER_PRG.name}")

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
        print("ERROR: cannot connect to VICE monitor"); p.terminate(); return 1
    print("monitor connected")

    # Drain banner
    expect_prompt(s, timeout=5.0)

    # Set watch on $00:$00FC stores
    out = cmd(s, "watch store $00fc $00fc", timeout=5.0)
    print(f"watch setup: {out.strip()[-150:]}")

    raw_path = OUT_DIR / "raw.txt"
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write("--- watch setup ---\n" + out)

    # Resume execution
    print(f"Resuming for {args.secs}s real-time; capturing writer events ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    events = []
    end_t = time.time() + args.secs
    buf = b""
    last_print = time.time()

    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except (socket.timeout, OSError):
            if time.time() - last_print > 10.0:
                elapsed = args.secs - (end_t - time.time())
                print(f"  t={elapsed:.0f}s events={len(events)}")
                last_print = time.time()
            continue
        if not ch: break
        buf += ch
        text_chunk = ch.decode(errors='replace')
        raw_f.write(text_chunk); raw_f.flush()

        if b"(C:$" in buf or b"(R:$" in buf:
            text = buf.decode(errors='replace')
            for m in WATCH_HDR_RE.finditer(text):
                target = "$" + m.group(1)
                rest = text[m.end():]
                rm = REG_LINE_RE.search(rest)
                if rm:
                    pbr, pc, a = (rm.group(1).lower(),
                                  rm.group(2).lower(),
                                  rm.group(3).lower())
                    events.append((target, pbr, pc, a))
                    if len(events) <= 20 or len(events) % 100 == 0:
                        print(f"  ev{len(events):>4}: tgt={target} "
                              f"PBR=${pbr} PC=${pc} A=${a}")
            try:
                s.sendall(b"x\r\n")
            except OSError:
                break
            buf = b""

    print(f"\nTotal watch events captured: {len(events)}")

    # Pause + dump final state
    try:
        s.sendall(b"\r\n"); time.sleep(0.5)
        # drain
        s.settimeout(1.0)
        try:
            while True:
                ch = s.recv(65536)
                if not ch: break
        except (socket.timeout, OSError):
            pass
        mem_fc = cmd(s, "m $00fc $00fe", timeout=5.0)
        mem_74 = cmd(s, "m $0074 $0076", timeout=5.0)
        # Strip non-ASCII to avoid Windows console encoding issues
        mem_fc_clean = mem_fc.encode('ascii', errors='replace').decode('ascii')
        mem_74_clean = mem_74.encode('ascii', errors='replace').decode('ascii')
        print(f"\nFinal $00:$00FC: {mem_fc_clean.strip()[-150:]}")
        print(f"Final $00:$0074: {mem_74_clean.strip()[-150:]}")
        raw_f.write("\n--- final ---\n" + mem_fc + mem_74)
    except Exception as e:
        print(f"final dump failed: {e}")

    # Frequency analysis
    pc_writers = Counter((pbr, pc) for _, pbr, pc, _ in events)
    val_ring = [a for _, _, _, a in events[-10:]]

    print(f"\nLast 10 stored A values: {val_ring}")
    print("\nWriter (PBR:PC) frequency (top 30):")
    for (pbr, pc), n in pc_writers.most_common(30):
        print(f"  ${pbr}:${pc}  n={n}")

    # Save summary
    with open(OUT_DIR / "summary.txt", 'w', errors='replace') as f:
        f.write(f"VICE $00FC writer trace ({args.secs}s real-time, NO warp)\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"Total events: {len(events)}\n\n")
        f.write("Writer PBR:PC frequency:\n")
        for (pbr, pc), n in pc_writers.most_common():
            f.write(f"  ${pbr}:${pc}  n={n}\n")
        f.write(f"\nLast 10 A values: {val_ring}\n")
        f.write("\nFirst 30 events:\n")
        for ev in events[:30]:
            f.write(f"  {ev}\n")
        f.write("\n=== HW Probe B baseline ===\n")
        f.write("CY=23389 WP=$2C:8605 V=E8 E8 F6 0E G=$00:077D\n")

    print(f"\nSummary -> {OUT_DIR / 'summary.txt'}")

    raw_f.close()
    try: s.sendall(b"quit\r\n"); s.close()
    except OSError: pass
    time.sleep(1)
    try: p.terminate()
    except Exception: pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
