#!/usr/bin/env python3
"""VICE reference for $00:$00FC writer ring.

Hardware Probe B (v293 RTL) shows on full-loader Doom run:
  CY = 23,389 writes
  V  = E8 E8 F6 0E (newest)
  WP = $2C:$8605 (most recent writer)
  G  = 7D 07 00 ($0074-$0076 = $00:$077D loader address)

This tool runs xscpu64 with loader.prg + doom.reu under VICE warp,
sets watch on $00:$00FC writes, captures all writer-PC events for a
configurable warp duration, and reports:
  - total event count (compare to hardware CY)
  - writer-PC frequency table (compare to hardware WP)
  - last 4 values written (compare to hardware V ring)
  - final $00:$00FC value
  - final $00:$0074-$0076 value (compare to hardware G)

Uses tools/vice_oracle.py infrastructure (proven to launch xscpu64 +
loader.prg + doom.reu correctly per vice_dump_gameplay_state.py).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys
import time
from collections import Counter

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import ViceOracle, VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"
OUT_DIR = TOOLS / "doom_vice_fc_ref"

# Watch hit pattern. After a watch fires VICE emits something like:
#   #1 (Stop on store at $00fc)
#   .;<pbr> <pc> <ir> ... A:<a> X:<x> Y:<y> ...
# Then prompt (C:$<pc>) waits.
WATCH_HDR_RE = re.compile(
    r"#\d+\s*\(Stop on store at\s*\$([0-9a-fA-F]+)\)"
)
# Register dump line — xscpu64 native-mode dump format:
#   .;<pbr> <pc> <ir> <a> <x> <y> <sp> <p> <e>
# We only need PBR + PC + accumulator (A holds the value just stored).
REG_LINE_RE = re.compile(
    r"\.;\s*([0-9a-fA-F]{2})\s+([0-9a-fA-F]{4})\s+"
    r"[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warp-secs", type=float, default=180.0,
                    help="seconds of VICE warp wallclock to capture (default 180)")
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--out", type=pathlib.Path, default=OUT_DIR)
    args = ap.parse_args()

    if not LOADER_PRG.exists():
        print(f"ERROR: {LOADER_PRG} not found", file=sys.stderr); return 2
    if not DOOM_REU.exists():
        print(f"ERROR: {DOOM_REU} not found", file=sys.stderr); return 2

    args.out.mkdir(parents=True, exist_ok=True)

    extra = [
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", str(DOOM_REU),
        "-autostartprgmode", "1",
        "-autostart", str(LOADER_PRG),
        "+sound",
    ]

    print(f"Launching xscpu64 with REU + autostart={LOADER_PRG.name}")
    v = ViceOracle(vice_exe=args.vice)
    raw_path = args.out / "raw.txt"
    raw_f = open(raw_path, 'w', errors='replace')

    try:
        v.launch(extra_args=extra)
        print("VICE monitor connected; cpu paused at boot/init")

        # Set watch on writes to $00:$00FC. Default memspace = cpu (motherboard
        # RAM bank $00). Watch fires on every store; CPU stops, prints reg dump
        # + prompt, waits for resume.
        out = v._cmd("watch store $00fc $00fc", timeout=5.0)
        print("watch store $00fc:", out.strip()[-200:])
        raw_f.write("--- watch setup ---\n" + out)

        # Resume; capture for warp_secs.
        print(f"Resuming for {args.warp_secs}s warp; capturing all watch events ...")
        v._sock.sendall(b"x\r\n")
        v._sock.settimeout(2.0)

        events = []  # list of (target, pbr, pc, a)
        end_t = time.time() + args.warp_secs
        buf = b""
        last_print = time.time()

        while time.time() < end_t:
            try:
                ch = v._sock.recv(65536)
            except (OSError, TimeoutError):
                # Periodic progress print
                if time.time() - last_print > 10.0:
                    print(f"  t={time.time() - (end_t - args.warp_secs):.0f}s "
                          f"events={len(events)}")
                    last_print = time.time()
                continue
            if not ch:
                break
            buf += ch
            text_chunk = ch.decode(errors='replace')
            raw_f.write(text_chunk); raw_f.flush()

            # Each watch hit ends with a prompt. Process whole-buffer when
            # prompt seen.
            if b"(C:$" in buf or b"(R:$" in buf:
                text = buf.decode(errors='replace')
                # Find every watch-hit header in the chunk
                for m in WATCH_HDR_RE.finditer(text):
                    target = "$" + m.group(1)
                    # Find the next reg line after this header
                    rest = text[m.end():]
                    rm = REG_LINE_RE.search(rest)
                    if rm:
                        pbr, pc, a = rm.group(1), rm.group(2), rm.group(3)
                        events.append((target, pbr.lower(), pc.lower(), a.lower()))
                # Resume and clear buf
                try:
                    v._sock.sendall(b"x\r\n")
                except OSError:
                    break
                buf = b""

        print(f"\nTotal watch events captured: {len(events)}")

        # Force back into monitor for final state dump
        try:
            v._sock.sendall(b"\r\n")
            time.sleep(0.5)
            v._drain(idle_s=0.5, max_s=3.0)
        except OSError:
            pass

        # Dump current $00FC and $0074-$0076 values
        try:
            mem_fc = v._cmd("m $00fc $00fe", timeout=5.0)
            mem_74 = v._cmd("m $0074 $0076", timeout=5.0)
            print("\nFinal $00:$00FC..$00FE:\n" + mem_fc.strip())
            print("Final $00:$0074..$0076:\n" + mem_74.strip())
            raw_f.write("\n--- final mem ---\n" + mem_fc + mem_74)
        except Exception as e:
            print(f"final mem dump failed: {e}")

        # Frequency analysis
        pc_writers = Counter((pbr, pc) for _, pbr, pc, _ in events)
        val_ring = [a for _, _, _, a in events[-10:]]
        print(f"\nLast 10 stored A values (newest last): {val_ring}")
        print("\nWriter (PBR:PC) frequency (top 20):")
        for (pbr, pc), n in pc_writers.most_common(20):
            print(f"  ${pbr}:${pc}  n={n}")

        # Comparison vs hardware Probe B
        print("\n=== HARDWARE PROBE B BASELINE (v293, full loader) ===")
        print("  CY = 23,389 (0x5B5D)  — total writes to $00:$00FC")
        print("  V  = E8 E8 F6 0E      — last 4 values written (newest=0E)")
        print("  WP = $2C:$8605        — most recent writer-PC")
        print("  G  = 7D 07 00         — $00:$0074-$0076 = $00:$077D")
        print("\n=== VICE REFERENCE (this run) ===")
        print(f"  events captured = {len(events)}")
        if events:
            top = pc_writers.most_common(1)[0]
            print(f"  most-frequent writer = ${top[0][0]}:${top[0][1]} "
                  f"(n={top[1]})")
            print(f"  most-recent writer   = ${events[-1][1]}:${events[-1][2]} "
                  f"(A=${events[-1][3]})")

        # Save summary
        with open(args.out / "summary.txt", 'w', errors='replace') as f:
            f.write(f"VICE $00FC writer reference ({args.warp_secs}s warp)\n")
            f.write("=" * 60 + "\n\n")
            f.write(f"Total events: {len(events)}\n\n")
            f.write("Writer PBR:PC frequency:\n")
            for (pbr, pc), n in pc_writers.most_common():
                f.write(f"  ${pbr}:${pc}  n={n}\n")
            f.write(f"\nLast 10 values: {val_ring}\n")
            f.write(f"\nHW Probe B baseline: CY=23389 V=E8 E8 F6 0E "
                    f"WP=$2C:8605 G=$00:077D\n")
        print(f"\nSummary -> {args.out / 'summary.txt'}")

    finally:
        raw_f.close()
        v.shutdown()

    return 0


if __name__ == '__main__':
    sys.exit(main())
