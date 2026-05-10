#!/usr/bin/env python3
"""VICE: snapshot $00:$0700-$07FF at multiple times during Doom run.

Goal: discover WHEN the JIT trampolines first appear at $00:$0700-$07FF.

Per discovery 2026-05-10:
  - Watch trace caught 41,039 INC events but ZERO emit events.
  - That means trampoline bodies are installed by something OTHER than
    CPU stores — most likely REU DMA (which doesn't trigger VICE watch).
  - If true, the bug on our hardware is in the REU→bank-$00-RAM data
    path (not the recompiler runtime per se).

Time-series snapshots at: pre-loader (boot), post-autostart, +5s, +15s,
+30s, +45s. Compares contents to find when bytes first become non-stock.
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
OUT_DIR = TOOLS / "doom_vice_0700_timeseries"
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


def snapshot(s, label):
    """Pause, dump $0700-$07FF and registers, resume."""
    s.sendall(b"r\r\n")  # registers — re-enters monitor prompt
    regs = expect_prompt(s, timeout=10.0).decode(errors="replace")
    mem = cmd(s, "m 0700 07ff", timeout=5.0)
    return {"label": label, "regs": regs, "mem": mem}


def safe_print(line):
    print(line.encode("ascii", errors="replace").decode("ascii"))


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    schedule_secs = [0.5, 3.0, 8.0, 15.0, 30.0, 45.0]
    label_for = {
        0.5: "early-boot",
        3.0: "loader-likely-running",
        8.0: "loader-mid",
        15.0: "loader-late-or-game-start",
        30.0: "in-game",
        45.0: "in-game-stable",
    }

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
    print("Launching xscpu64 for $00:$0700-$07FF time-series snapshots")

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

    # Initial snapshot at startup (still paused at autostart)
    snaps = []
    snaps.append(snapshot(s, "initial-boot-paused"))
    safe_print(f"  snap 0: initial-boot-paused")

    # Resume; pause at each scheduled time and snapshot
    last_t = 0.0
    for t in schedule_secs:
        delta = t - last_t
        s.sendall(b"x\r\n")
        time.sleep(delta)
        snap = snapshot(s, f"t={t}s {label_for[t]}")
        snaps.append(snap)
        safe_print(f"  snap @ t={t}s: {label_for[t]}")
        last_t = t

    # Save raw output
    out_path = OUT_DIR / "snapshots.txt"
    with open(out_path, "w", errors="replace") as f:
        for snap in snaps:
            f.write("=" * 60 + "\n")
            f.write(f"SNAPSHOT: {snap['label']}\n")
            f.write("=" * 60 + "\n")
            f.write("--- regs ---\n")
            f.write(snap["regs"])
            f.write("\n--- mem $00:$0700-$07FF ---\n")
            f.write(snap["mem"])
            f.write("\n")
    safe_print(f"\nSaved -> {out_path}")

    # Diff first vs each later snapshot
    def extract_bytes(mem_text):
        """Pull the 256 bytes from VICE 'm' output."""
        out = []
        for line in mem_text.splitlines():
            line = line.encode("ascii", errors="replace").decode("ascii")
            # VICE format: ">C:0700  92 a9 01 00  85 94 64 96  ..."
            if ":" not in line[:8]:
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            for tok in parts[1:]:
                if len(tok) == 2 and all(c in "0123456789abcdefABCDEF" for c in tok):
                    try:
                        out.append(int(tok, 16))
                    except ValueError:
                        pass
                if len(out) >= 256:
                    break
            if len(out) >= 256:
                break
        return out[:256]

    safe_print("\n=== diff vs initial ===")
    initial_bytes = extract_bytes(snaps[0]["mem"])
    safe_print(f"  initial first 16: {[hex(b) for b in initial_bytes[:16]]}")
    for snap in snaps[1:]:
        b = extract_bytes(snap["mem"])
        if not b:
            safe_print(f"  {snap['label']}: (no bytes parsed)")
            continue
        diff_count = sum(1 for i in range(min(len(b), len(initial_bytes))) if b[i] != initial_bytes[i])
        first_diff = next((i for i in range(min(len(b), len(initial_bytes))) if b[i] != initial_bytes[i]), -1)
        safe_print(f"  {snap['label']}: {diff_count}/256 bytes changed; first diff at off={first_diff:#x}")
        if first_diff >= 0:
            safe_print(f"    initial[{first_diff:#x}]={initial_bytes[first_diff]:#x} now[{first_diff:#x}]={b[first_diff]:#x}")

    try: s.sendall(b"quit\r\n"); s.close()
    except OSError: pass
    time.sleep(1)
    try: p.terminate()
    except Exception: pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
