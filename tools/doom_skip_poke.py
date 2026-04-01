#!/usr/bin/env python3
"""POKE a minimal Doom skip loader at $C000, then SYS49152.

The skip loader:
  SEI / CLD / CLC / XCE / STA $D07B / JML $200000
  = 11 bytes, enters native mode + turbo, jumps to doom.reu entry

Requires mtype2.py daemon running on MiSTer.
"""
import os, time, sys

PIPE = "/tmp/mtype2.pipe"

def send(msg):
    fd = os.open(PIPE, os.O_WRONLY)
    os.write(fd, (msg + "\n").encode())
    os.close(fd)

# Skip loader at $C000: SEI, CLD, CLC, XCE, STA $D07B, JML $200000
skip = [0x78, 0xD8, 0x18, 0xFB, 0x8D, 0x7B, 0xD0, 0x5C, 0x00, 0x00, 0x20]

# POKE in two chunks (C64 input buffer is ~80 chars)
print(f"POKEing skip loader ({len(skip)} bytes) at $C000...")
chunk1 = ":".join(f"POKE{49152+i},{b}" for i, b in enumerate(skip[:5]))
send(f'{chunk1} enter wait:1.5')
time.sleep(2.5)
chunk2 = ":".join(f"POKE{49152+5+i},{b}" for i, b in enumerate(skip[5:]))
send(f'{chunk2} enter wait:1.5')
time.sleep(2.5)

# Verify first 6 bytes
print("Verifying...")
send('FORI=0TO10:PRINTPEEK(49152+I);:NEXT enter wait:2')
time.sleep(4)

if "--launch" in sys.argv:
    print("Launching SYS49152...")
    send('SYS49152 enter')
    time.sleep(2)
    print("Launched!")
else:
    print("Verify done. Use --launch to run SYS49152")
