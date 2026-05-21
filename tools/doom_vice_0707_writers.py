#!/usr/bin/env python3
"""VICE writer trace for $00:$0707 wait variable.

Per off-device finding (project_doom_vs_wolf3d_0707_differential.md):
  Doom has 187 CMP $00:$0707,X / 80 indirect-jump consumers / 2 BCS+3/BNE-2
  wait patterns referencing $0707. Wolf3D has zero. So $0707 is real
  Doom-specific data the recompiled MIPS code references.

Per off-device search (project_doom_0707_no_real_producers.md):
  ZERO real producers found via byte search of doom.reu. All 14 candidate
  writers are false positives inside data tables.

This tool spawns xscpu64 (VICE), runs Doom's loader.prg + doom.reu (16 MB),
sets a watch on stores to $00:$0707, captures every writer-PC for ~120s.
Goal: find the writer that VICE successfully runs but our hardware doesn't.
That's the next code-path divergence to investigate.

VICE runs Doom past the hang point in xscpu64 per memory entry
project_doom_vice_oracle_runs_doom.md, so writer events should fire
during the run if they exist.
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
from collections import Counter, defaultdict

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from vice_oracle import VICE_EXE_DEFAULT  # type: ignore

LOADER_PRG = REPO / "loader.prg"
DOOM_REU = REPO / "doom.reu"
OUT_DIR = TOOLS / "doom_vice_0707_writers"
PORT = 6510

DISASM_RE = re.compile(
    r"\.([0-9a-fA-FCRcr]+):([0-9a-fA-F]{4})\s+"
    r"([0-9a-fA-F]{2}(?:\s+[0-9a-fA-F]{2})*)\s+"
    r"(\S+)\s+(\S+)"
)
WATCH_HIT_RE = re.compile(r"#\d+\s*\(Stop on store ([0-9a-fA-F]+)\)")


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
    ap.add_argument("--secs", type=float, default=120.0)
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
    ap.add_argument("--watch-range", type=str, default="0707",
                    help="Single addr (0707) or range (0700-07ff)")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    if "-" in args.watch_range:
        lo, hi = args.watch_range.split("-")
        watch_cmd = f"watch store ${lo} ${hi}"
    else:
        a = args.watch_range
        watch_cmd = f"watch store ${a} ${a}"

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
    print(f"Launching xscpu64 (NO warp) for $0707 writer trace")
    print(f"watch cmd: {watch_cmd}")

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

    out1 = cmd(s, watch_cmd, timeout=5.0)
    print(f"watch setup: {out1.strip()[-150:]}")

    raw_path = OUT_DIR / "raw.txt"
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write("--- watch setup ---\n" + out1)

    print(f"Resuming for {args.secs}s real-time ...")
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
            for m in WATCH_HIT_RE.finditer(text):
                target = "$" + m.group(1).lower()
                pre = text[:m.start()]
                last_disasm = None
                for dm in DISASM_RE.finditer(pre):
                    last_disasm = dm
                if last_disasm:
                    bank = last_disasm.group(1).lower()
                    pc = last_disasm.group(2).lower()
                    op_bytes = last_disasm.group(3)
                    mnemonic = last_disasm.group(4)
                    operand = last_disasm.group(5)
                    events.append((target, bank, pc, op_bytes, mnemonic, operand))
                    if len(events) <= 30 or len(events) % 50 == 0:
                        print(f"  ev{len(events):>4}: tgt={target} "
                              f"PB={bank}:{pc}  {op_bytes}  {mnemonic} {operand}")
            try:
                s.sendall(b"x\r\n")
            except OSError:
                break
            buf = b""

    print(f"\nTotal watch events: {len(events)}")

    try:
        s.sendall(b"\r\n"); time.sleep(0.5)
        try:
            s.settimeout(1.0)
            while True:
                ch = s.recv(65536)
                if not ch: break
        except (socket.timeout, OSError): pass
        mem_07 = cmd(s, "m $0700 $07ff", timeout=5.0)
        mem_07_clean = mem_07.encode('ascii', errors='replace').decode('ascii')
        print(f"Final $00:$0700-$07FF dump (first 240 chars):")
        print(mem_07_clean[:240])
        raw_f.write("\n--- final $0700-$07ff dump ---\n" + mem_07)
    except Exception as e:
        print(f"final dump failed: {e}")

    target_tally = Counter(t for t, _, _, _, _, _ in events)
    print("\nWrites per target:")
    for t, n in target_tally.most_common():
        print(f"  {t}: {n}")

    print("\nWriter PB:PC for each target:")
    by_target = defaultdict(list)
    for t, b, p, ob, mn, op in events:
        by_target[t].append((b, p, ob, mn, op))
    for t in sorted(by_target.keys()):
        print(f"  Target {t}:")
        c = Counter((b, p) for b, p, _, _, _ in by_target[t])
        for (b, p), n in c.most_common(10):
            ex = next((e for e in by_target[t] if e[0] == b and e[1] == p), None)
            if ex:
                print(f"    {b}:{p}  n={n}  {ex[2]}  {ex[3]} {ex[4]}")

    with open(OUT_DIR / "summary.txt", 'w', errors='replace') as f:
        f.write(f"VICE $00:$0707 writer trace ({args.secs}s real-time)\n")
        f.write(f"watch cmd: {watch_cmd}\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"Total events: {len(events)}\n\n")
        f.write("Target tally:\n")
        for t, n in target_tally.most_common():
            f.write(f"  {t}: {n}\n")
        f.write("\nWriter PB:PC per target:\n")
        for t in sorted(by_target.keys()):
            f.write(f"  Target {t}:\n")
            c = Counter((b, p) for b, p, _, _, _ in by_target[t])
            for (b, p), n in c.most_common():
                ex = next((e for e in by_target[t]
                           if e[0] == b and e[1] == p), None)
                f.write(f"    {b}:{p}  n={n}  {ex[2] if ex else ''}  "
                        f"{ex[3] if ex else ''} {ex[4] if ex else ''}\n")
        f.write("\nFirst 50 events (target, bank, pc, opbytes, mnemonic, op):\n")
        for ev in events[:50]:
            f.write(f"  {ev}\n")
        f.write("\n=== HW vs VICE expectation ===\n")
        f.write("HW: stuck in wait at $41:$DB93 polling $00:$0707,X\n")
        f.write("VICE: should successfully write $0707 to escape the wait\n")

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
