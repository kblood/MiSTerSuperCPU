#!/usr/bin/env python3
"""VICE writer trace for $00:$0074-$0076 dispatcher pointer.

Per smoking-gun finding (project_doom_v293_dispatcher_pointer_smoking_gun.md):
  HW   $00:$0074-$0076 = $7D $07 $00 (loader stale)
  VICE $00:$0074-$0076 = $85 $94 $A0 (Doom dispatcher → $A0:$9485)

This tool runs xscpu64 WITHOUT -warp (watches don't fire under warp),
sets watch on $0074 stores, captures every writer-PC. Goal: find the
specific (PBR, PC, value) that installs $85/$94/$A0 — this is the
dispatcher install site that runs on VICE but not on hardware.

VICE output format (verified in tools/doom_vice_fc_trace/raw.txt):
  .C:2ca5  85 FC       STA $FC  103801771
  (C:$2ca7) #1 (Stop on store 00fc)  287/$11f,  20/$14 7

So watch hits emit: disasm-style line + (Stop on store XXXX) line.
Parser extracts the disasm PC (the writer-PC).
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
OUT_DIR = TOOLS / "doom_vice_74_writers"
PORT = 6510

# VICE disasm line preceding watch hit:
#   .<bank-or-C>:<pc>  <op-bytes>  <disasm>  [counter]
DISASM_RE = re.compile(
    r"\.([0-9a-fA-FCRcr]+):([0-9a-fA-F]{4})\s+"
    r"([0-9a-fA-F]{2}(?:\s+[0-9a-fA-F]{2})*)\s+"
    r"(\S+)\s+(\S+)"
)
# Watch hit announcement:
#   #1 (Stop on store XXXX)
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
    ap.add_argument("--secs", type=float, default=180.0)
    ap.add_argument("--vice", type=str, default=VICE_EXE_DEFAULT)
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
    print(f"Launching xscpu64 (NO warp) for $0074-$0076 writer trace")

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

    # Watch $0074, $0075, $0076 stores
    out1 = cmd(s, "watch store $0074 $0076", timeout=5.0)
    print(f"watch setup: {out1.strip()[-150:]}")

    raw_path = OUT_DIR / "raw.txt"
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write("--- watch setup ---\n" + out1)

    # Resume
    print(f"Resuming for {args.secs}s real-time ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    events = []  # list of (target, bank, pc, opcode_str, disasm)
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
            # Find every watch-hit line
            for m in WATCH_HIT_RE.finditer(text):
                target = "$" + m.group(1).lower()
                # Look BACKWARD in the text for the matching disasm line
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

    # Pause + dump final state
    try:
        s.sendall(b"\r\n"); time.sleep(0.5)
        try:
            s.settimeout(1.0)
            while True:
                ch = s.recv(65536)
                if not ch: break
        except (socket.timeout, OSError): pass
        mem_74 = cmd(s, "m $0074 $0076", timeout=5.0)
        mem_74_clean = mem_74.encode('ascii', errors='replace').decode('ascii')
        print(f"Final $00:$0074-$0076: {mem_74_clean.strip()[-150:]}")
        raw_f.write("\n--- final ---\n" + mem_74)
    except Exception as e:
        print(f"final dump failed: {e}")

    # Per-target tally
    target_tally = Counter(t for t, _, _, _, _, _ in events)
    print("\nWrites per target:")
    for t, n in target_tally.most_common():
        print(f"  {t}: {n}")

    # Writer-PC frequency (per target)
    print("\nWriter PB:PC for each target:")
    by_target = defaultdict(list)
    for t, b, p, ob, mn, op in events:
        by_target[t].append((b, p, ob, mn, op))
    for t in sorted(by_target.keys()):
        print(f"  Target {t}:")
        c = Counter((b, p) for b, p, _, _, _ in by_target[t])
        for (b, p), n in c.most_common(10):
            # Find one example op for this PC
            ex = next((e for e in by_target[t] if e[0] == b and e[1] == p), None)
            if ex:
                print(f"    {b}:{p}  n={n}  {ex[2]}  {ex[3]} {ex[4]}")

    # Save summary
    with open(OUT_DIR / "summary.txt", 'w', errors='replace') as f:
        f.write(f"VICE $00:$0074-$0076 writer trace ({args.secs}s real-time)\n")
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
        f.write("\n=== HW vs VICE comparison (smoking gun) ===\n")
        f.write("HW   $00:$0074-$0076 = $7D $07 $00 (loader stale)\n")
        f.write("VICE $00:$0074-$0076 = $85 $94 $A0 (Doom dispatcher)\n")

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
