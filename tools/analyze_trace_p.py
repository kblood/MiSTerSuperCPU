#!/usr/bin/env python3
"""Analyze a Doom crash UART log that includes the new P-per-entry trace buffer.

New trace line format (when frozen):
    ...existing UART fields... TR:xx PC:xxxx K:xx I:xx P:xx

The 32-entry buffer is streamed once per vblank, cycling trace_idx 0..31.
Each physical slot is independent — what we want is the LOGICAL order:
the buffer wraps at bug_wp, so the oldest entry is at slot wp and the newest
at slot (wp-1) mod 32.

Usage: python analyze_trace_p.py <uart.log>
"""
import re
import sys

TRACE_RE = re.compile(
    r'TR:([0-9A-F]{2}) PC:([0-9A-F]{4}) K:([0-9A-F]{2}) I:([0-9A-F]{2}) P:([0-9A-F]{2})'
)

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        log = f.read()

    # Collect one full pass of the buffer (32 entries), preferring the most
    # recent sweep in the log.
    entries = {}
    for line in log.splitlines():
        m = TRACE_RE.search(line)
        if not m:
            continue
        tr, pc, k, i, p = [int(g, 16) for g in m.groups()]
        entries[tr] = (pc, k, i, p)

    if len(entries) < 32:
        print(f"WARNING: only {len(entries)}/32 slots populated")

    # We don't know bug_wp from trace alone, but the ring boundary is where
    # the PC sequence jumps non-linearly (wraps back). Find it.
    slots = [entries.get(i) for i in range(32)]

    # Print in physical order first
    print("=== Physical slot order (TR:00 .. TR:1F) ===")
    for i, e in enumerate(slots):
        if e is None:
            print(f"  TR:{i:02X}  <missing>")
            continue
        pc, k, ir, p = e
        x_bit = (p >> 4) & 1
        m_bit = (p >> 5) & 1
        i_bit = (p >> 2) & 1
        flags = f"M={m_bit} X={x_bit} I={i_bit}"
        print(f"  TR:{i:02X}  K:{k:02X} PC:{pc:04X} I:{ir:02X} P:{p:02X}  [{flags}]")

    # Highlight P transitions
    print()
    print("=== P transitions ===")
    prev_p = None
    for i, e in enumerate(slots):
        if e is None:
            continue
        pc, k, ir, p = e
        if prev_p is not None and p != prev_p:
            changed_bits = p ^ prev_p
            changes = []
            for bit, name in [(7, 'N'), (6, 'V'), (5, 'M'), (4, 'X'),
                              (3, 'D'), (2, 'I'), (1, 'Z'), (0, 'C')]:
                if changed_bits & (1 << bit):
                    new = (p >> bit) & 1
                    changes.append(f"{name}{'+' if new else '-'}")
            print(f"  TR:{i:02X} K:{k:02X} PC:{pc:04X} I:{ir:02X}  "
                  f"P:{prev_p:02X}→{p:02X}  {' '.join(changes)}")
        prev_p = p

    # Highlight X=0 → X=1 specifically (the Doom question)
    print()
    print("=== X flag history (ordered by physical slot) ===")
    for i, e in enumerate(slots):
        if e is None:
            continue
        pc, k, ir, p = e
        x_bit = (p >> 4) & 1
        marker = "*** X=1 ***" if x_bit else "X=0"
        print(f"  TR:{i:02X} K:{k:02X} PC:{pc:04X} I:{ir:02X} P:{p:02X}  {marker}")


if __name__ == '__main__':
    main()
