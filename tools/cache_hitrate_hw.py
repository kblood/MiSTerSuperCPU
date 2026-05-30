#!/usr/bin/env python3
"""cache_hitrate_hw.py — read the in-HW read-only cpu_cache hit-rate observer.

more-turbo iter-4d. The observer (cache_observer in fpga64_sid_iec.vhd, build
md5 e5e899fc+) appends " HR:## HW:##" to every UART debug line:
  HR = HITs in the last completed 256-cacheable-read sliding window
       (saturating $FF; HR/256 = hit fraction, HR/2.56 = hit %). Sliding window
       => steady-state, immune to the cold-start compulsory misses that polluted
       the off-device cumulative numbers.
  HW = window-completion counter (wraps every 256 windows). If it advances across
       the capture, the observer is seeing real CPU read traffic (liveness).

This captures a UART window and reports the HR distribution = the real
steady-state cache hit rate for whatever workload is running. Run it during:
  (a) a real Doom run  -> SuperRAM steady-state (the Doom-payoff number), and
  (b) Lorenz scpu / a tight BASIC loop -> bank-$00 steady-state.
The mean HR is the GO/NO-GO input for the cache + variable-cadence-arbiter arc.

DOES NOT deploy or load anything — deploy/load are gated shared-MiSTer actions
done separately after a /tmp/CORENAME ownership check. This is read-only.

Usage:
  python tools/cache_hitrate_hw.py [seconds]          # default 60
  python tools/cache_hitrate_hw.py 90 --raw           # also dump raw HR/HW pairs
"""
import os
import re
import sys
import statistics

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mister_debug import ssh  # noqa: E402

PAIR_RE = re.compile(r'HR:([0-9A-Fa-f]{2})\s+HW:([0-9A-Fa-f]{2})')


def capture(seconds):
    # Ensure baud first (idempotent), then cat the UART for the window.
    ssh('stty -F /dev/ttyS1 115200 raw -echo', timeout=8)
    out, _, _ = ssh(f'timeout {seconds} cat /dev/ttyS1 2>/dev/null || true',
                    timeout=seconds + 8)
    return out or ''


def main():
    secs = 60
    raw = '--raw' in sys.argv
    for a in sys.argv[1:]:
        if a.isdigit():
            secs = int(a)

    print(f"Capturing UART for {secs}s (reading in-HW cpu_cache HR/HW observer)...")
    text = capture(secs)
    pairs = [(int(h, 16), int(w, 16)) for h, w in PAIR_RE.findall(text)]

    if not pairs:
        print("NO HR/HW fields found in UART. Checklist:")
        print("  - Is the iter-4d build (md5 e5e899fc+) deployed to _Test/C64.rbf?")
        print("  - Is Debug UART enabled in the OSD?")
        print(f"  - UART bytes captured: {len(text)}")
        return 1

    hrs = [h for h, _ in pairs]
    hws = [w for _, w in pairs]
    n = len(hrs)
    mean_hr = statistics.mean(hrs)
    med_hr = statistics.median(hrs)
    hw_advanced = len(set(hws)) > 1

    def pct(hr):
        return 100.0 * hr / 256.0

    print(f"\n== in-HW cpu_cache HIT-RATE (read-only observer) ==")
    print(f"  UART lines with HR/HW : {n}")
    print(f"  liveness (HW advanced): {hw_advanced}  (distinct HW values: {len(set(hws))})")
    if not hw_advanced:
        print("  !! HW did NOT advance -> observer saw no (new) cacheable reads.")
        print("     HR is then stale/meaningless; the CPU may be idle/halted or in I/O.")
    print(f"  HR mean : {mean_hr:6.1f}/256  = {pct(mean_hr):5.2f}% hit")
    print(f"  HR med  : {med_hr:6.1f}/256  = {pct(med_hr):5.2f}% hit")
    print(f"  HR min/max: {min(hrs)} ({pct(min(hrs)):.1f}%) / {max(hrs)} ({pct(max(hrs)):.1f}%)")
    print(f"\n  STEADY-STATE HIT RATE ~= {pct(mean_hr):.1f}%  "
          f"(mean of per-256-read windows over the run)")

    if raw:
        print("\n  raw (HR,HW) pairs:")
        for h, w in pairs:
            print(f"    HR={h:3d} ({pct(h):5.1f}%)  HW={w:3d}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
