#!/usr/bin/env python3
"""Patch doom.reu's $2C:$A95C trap to skip the halt and continue.

Hardware halts at $2C:$A95C via JML $2C:$A95C (4-byte self-loop trap).
Path is reached because music_num check fails (P65C816 divergence — VICE
runs Doom through). Patch replaces the trap with JML $2C:$860E so the
error handler's continuation block fires, advancing Doom's state machine.

If Doom continues after this patch:
  - confirms the trap is the only blocker
  - exposes whatever the next bug is (or playable Doom, unlikely)
If Doom hangs again somewhere else:
  - we've moved the bug, useful for triangulation

Original bytes at REU offset 0x2CA95C: 5C 5C A9 2C (JML $2C:$A95C)
Patched bytes:                          5C 0E 86 2C (JML $2C:$860E)
"""
import os, shutil

SRC = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DST = r"C:\LLM\C64\MiSTerSuperCPU\doom_patched_a95c.reu"

with open(SRC, 'rb') as f:
    data = bytearray(f.read())

trap_off = 0x2CA95C
orig = bytes(data[trap_off:trap_off+4])
print(f"Original bytes at REU offset 0x{trap_off:06X}: {' '.join(f'{b:02x}' for b in orig)}")
assert orig == bytes.fromhex("5c5ca92c"), "Trap bytes don't match expected — abort"

patch = bytes.fromhex("5c0e862c")  # JML $2C:$860E
data[trap_off:trap_off+4] = patch

print(f"Patched bytes:                       {' '.join(f'{b:02x}' for b in patch)}")
print(f"  was: JML $2C:$A95C (self-loop trap)")
print(f"  now: JML $2C:$860E (continuation handler)")

with open(DST, 'wb') as f:
    f.write(data)
print(f"\nWrote {DST} ({len(data)} bytes)")
