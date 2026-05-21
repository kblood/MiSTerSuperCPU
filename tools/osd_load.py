#!/usr/bin/env python3
"""Load doom.reu via MiSTer OSD using uinput with real keyboard VID/PID.

Mimics the 8BitDo Retro Keyboard's USB identifiers so MiSTer Main
treats this as a real keyboard and processes F12 for OSD."""

import struct, os, time, fcntl

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
EV_REP = 0x14
EV_MSC = 0x04

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)
for k in range(256):
    try:
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except:
        pass
# Use USB port 1.4 (unused) so MiSTer sees it as real USB
try:
    fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.4/input0\x00")
except OSError:
    pass

# Match real 8BitDo keyboard VID/PID
name = b"8BitDo 8BitDo Retro Keyboard\x00" + b"\x00" * 51  # 80 bytes total
ids = struct.pack("HHHH", 3, 0x2dc8, 0x5200, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64 * 4 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(8)  # Wait for MiSTer to detect

def tap(code):
    t = int(time.time())
    os.write(fd, struct.pack("IIHHi", t, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack("IIHHi", t, 0, EV_SYN, 0, 0))
    time.sleep(0.05)
    os.write(fd, struct.pack("IIHHi", t, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack("IIHHi", t, 0, EV_SYN, 0, 0))
    time.sleep(0.15)

# F12 to open OSD
print("F12")
tap(88)
time.sleep(2)

# Navigate down to Load REU (4 DOWNs from top)
for i in range(4):
    print(f"DOWN {i+1}")
    tap(108)
    time.sleep(0.5)

# ENTER to open file browser
print("ENTER (open browser)")
tap(28)
time.sleep(4)

# ENTER to select doom.reu (only REU file on USB)
print("ENTER (select file)")
tap(28)
time.sleep(2)

fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("DONE")
