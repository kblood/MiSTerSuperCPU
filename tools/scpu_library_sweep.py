#!/usr/bin/env python3
"""
SCPU library compatibility sweep (task #19, Lane A.3).

Iterates over a list of canonical SuperCPU PRGs/D64s, loads each on the
dev MiSTer, captures UART for a fixed window, and emits a pass/fail
table. Compatibility data feeds back into
docs/supercpu_feature_status.md §2 bug tracker.

Pass/fail criteria are per-title and stored in scpu_library_titles.json.
Sample criterion forms:
  * "uart_must_contain": substring required in captured UART
  * "uart_must_not_contain": substring that, if seen, is a fail
  * "duration_seconds": how long to wait before evaluating
  * "needs_keypress": optional keypress sequence sent after load

Default behavior:
  1. Reset MiSTer to clean state.
  2. Load PRG via tools/mister_debug.py load_prg.
  3. Capture duration_seconds of UART.
  4. Apply criteria, classify as PASS / FAIL / TIMEOUT.
  5. Append to logs/scpu_sweep_<timestamp>.csv.

Hardware-only — does not run if MiSTer is unreachable.

Usage:
  python tools/scpu_library_sweep.py [--titles <path>] [--filter <regex>]
"""

from __future__ import annotations

import argparse
import csv
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
TITLES_PATH = REPO / "tools" / "scpu_library_titles.json"
LOG_DIR = REPO / "logs"
MISTER_DEBUG = REPO / "tools" / "mister_debug.py"


def load_titles(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        print(f"error: titles file not found: {path}", file=sys.stderr)
        sys.exit(2)
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def run(cmd: list[str], timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def reset_mister() -> bool:
    """Hard reset by re-deploying the core. Some PRGs leave the system in
    a state where the debug-UART formatter goes silent (e.g. Asterix
    title screen idle loop) — re-flashing the rbf gives every title a
    cold-boot baseline."""
    rbf = REPO / "C64_MiSTer" / "output_files" / "C64.rbf"
    if not rbf.exists():
        cp = run([sys.executable, str(MISTER_DEBUG), "status"], timeout=15)
        return cp.returncode == 0
    cp = run(
        [sys.executable, str(MISTER_DEBUG), "deploy", str(rbf)],
        timeout=120,
    )
    if cp.returncode != 0:
        return False
    time.sleep(3)
    return True


def load_prg(prg_path: pathlib.Path) -> bool:
    cp = run(
        ["python", str(MISTER_DEBUG), "load_prg", str(prg_path)],
        timeout=60,
    )
    return cp.returncode == 0


def capture_uart(seconds: int) -> str:
    cp = run(
        ["python", str(MISTER_DEBUG), "uart", str(seconds)],
        timeout=seconds + 30,
    )
    return cp.stdout


def evaluate(title: dict, uart: str) -> tuple[str, str]:
    """Return (verdict, reason)."""
    must_contain = title.get("uart_must_contain")
    must_not_contain = title.get("uart_must_not_contain")
    if must_contain and must_contain not in uart:
        return "FAIL", f"missing required UART text: {must_contain!r}"
    if must_not_contain and must_not_contain in uart:
        return "FAIL", f"found forbidden UART text: {must_not_contain!r}"
    return "PASS", "criteria met"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--titles", type=pathlib.Path, default=TITLES_PATH)
    p.add_argument("--filter", type=str, default=None,
                   help="Regex over title.name; only matching titles run.")
    p.add_argument("--dry-run", action="store_true",
                   help="Print plan without invoking MiSTer.")
    args = p.parse_args()

    titles = load_titles(args.titles)
    if args.filter:
        rx = re.compile(args.filter)
        titles = [t for t in titles if rx.search(t["name"])]
    if not titles:
        print("no titles match filter", file=sys.stderr)
        return 1

    LOG_DIR.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    csv_path = LOG_DIR / f"scpu_sweep_{stamp}.csv"
    print(f"Sweep plan: {len(titles)} titles -> {csv_path}")

    if args.dry_run:
        for t in titles:
            print(f"  - {t['name']:<24} prg={t.get('prg', '?')} dur={t.get('duration_seconds', 30)}s")
        return 0

    if not reset_mister():
        print("error: cannot reach MiSTer; abort.", file=sys.stderr)
        return 3

    rows: list[dict] = []
    for idx, t in enumerate(titles):
        print(f"\n--- {t['name']} ---")
        # Cold-boot the system before each title so a previously loaded
        # PRG can't leave UART silent for the next test.
        if idx > 0:
            if not reset_mister():
                rows.append({"name": t["name"], "verdict": "FAIL",
                             "reason": "reset_mister failed", "uart_bytes": 0})
                continue

        prg_field = t.get("prg")
        if prg_field is None:
            # cold-boot smoke: no PRG, just capture UART
            pass
        else:
            prg = REPO / prg_field
            if not prg.exists():
                rows.append({"name": t["name"], "verdict": "SKIP",
                             "reason": f"prg missing: {prg}", "uart_bytes": 0})
                print(f"  {t['name']:<24} SKIP (prg missing)")
                continue
            if not load_prg(prg):
                rows.append({"name": t["name"], "verdict": "FAIL",
                             "reason": "load_prg failed", "uart_bytes": 0})
                print(f"  {t['name']:<24} FAIL (load_prg)")
                continue

        # Optional autorun keypresses (e.g. "RUN\\n")
        keys = t.get("keys")
        if keys:
            run(["python", str(MISTER_DEBUG), "keys", keys], timeout=30)

        dur = int(t.get("duration_seconds", 30))
        uart = capture_uart(dur)
        verdict, reason = evaluate(t, uart)
        rows.append({"name": t["name"], "verdict": verdict,
                     "reason": reason, "uart_bytes": len(uart)})
        print(f"  {t['name']:<24} {verdict}  ({reason})")
        time.sleep(2)

    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["name", "verdict", "reason", "uart_bytes"])
        w.writeheader()
        w.writerows(rows)

    n_pass = sum(1 for r in rows if r["verdict"] == "PASS")
    n_fail = sum(1 for r in rows if r["verdict"] == "FAIL")
    n_skip = sum(1 for r in rows if r["verdict"] == "SKIP")
    print(f"\n=== sweep complete: {n_pass} pass / {n_fail} fail / {n_skip} skip ===")
    print(f"csv: {csv_path}")
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
