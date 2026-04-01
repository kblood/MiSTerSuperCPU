#!/usr/bin/env python3
"""POKE Doom copier code via mtype2 daemon, then launch."""
import os, time

PIPE = "/tmp/mtype2.pipe"

def send(msg):
    fd = os.open(PIPE, os.O_WRONLY)
    os.write(fd, (msg + "\n").encode())
    os.close(fd)

# Copier at $C000: copies 1KB from bank $20:$0000 to $4000, JML $00:4000
copier = [
    0xA9, 0x00, 0x85, 0xFB, 0xA9, 0x00, 0x85, 0xFC,
    0xA9, 0x20, 0x85, 0xFD, 0x8D, 0x7B, 0xD0, 0x18,
    0xFB, 0xE2, 0x20, 0xC2, 0x10, 0xA0, 0x00, 0x00,
    0xB7, 0xFB, 0x99, 0x00, 0x40, 0xC8, 0xC0, 0x00,
    0x04, 0xD0, 0xF5, 0x5C, 0x00, 0x40, 0x00,
]

# LDA long verify at $C100
verify = [0x18, 0xFB, 0xAF, 0x00, 0x00, 0x20, 0xE2, 0x30, 0xFB, 0x85, 0x02, 0x60]

print("POKEing copier at $C000...")
for i in range(0, len(copier), 3):
    chunk = copier[i:i+3]
    poke_str = ":".join(f"POKE{49152+i+j},{b}" for j, b in enumerate(chunk))
    send(f'{poke_str} enter wait:1.5')
    time.sleep(2)

print("POKEing verify at $C100...")
for i in range(0, len(verify), 4):
    chunk = verify[i:i+4]
    poke_str = ":".join(f"POKE{49408+i+j},{b}" for j, b in enumerate(chunk))
    send(f'{poke_str} enter wait:1.5')
    time.sleep(2)

print("Verifying doom data...")
send('SYS49408:PRINTPEEK(2) enter wait:3')
time.sleep(5)

print("Verifying copier code...")
send('FORI=0TO5:PRINTPEEK(49152+I);:NEXT enter wait:2')
time.sleep(4)

if "--launch" in __import__("sys").argv:
    print("Launching copier (SYS49152)...")
    send('SYS49152 enter')
    time.sleep(2)
    print("Launched!")
else:
    print("Verify done. Use --launch to run SYS49152")
