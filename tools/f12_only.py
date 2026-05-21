#!/usr/bin/env python3
"""Press F12 to open MiSTer OSD, using 8BitDo keyboard VID/PID."""
import struct, os, time, fcntl

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)   # UI_SET_EVBIT, EV_KEY
fcntl.ioctl(fd, 0x40045564, 0x14) # UI_SET_EVBIT, EV_REP
fcntl.ioctl(fd, 0x40045564, 0x04) # UI_SET_EVBIT, EV_MSC
for k in range(256):
    try: fcntl.ioctl(fd, 0x40045565, k)  # UI_SET_KEYBIT
    except: pass
try: fcntl.ioctl(fd, 0x4004556C, b"usb-ffb40000.usb-1.4/input0\x00")
except: pass
name = b"8BitDo 8BitDo Retro Keyboard\x00" + b"\x00" * 51
ids = struct.pack("HHHH", 3, 0x2dc8, 0x5200, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, 0x5501)  # UI_DEV_CREATE
time.sleep(8)

def tap(code):
    t = int(time.time())
    os.write(fd, struct.pack("IIHHi", t, 0, 1, code, 1))
    os.write(fd, struct.pack("IIHHi", t, 0, 0, 0, 0))
    time.sleep(0.05)
    os.write(fd, struct.pack("IIHHi", t, 0, 1, code, 0))
    os.write(fd, struct.pack("IIHHi", t, 0, 0, 0, 0))
    time.sleep(0.15)

print("Pressing F12...")
tap(88)
time.sleep(5)

fcntl.ioctl(fd, 0x5502)  # UI_DEV_DESTROY
os.close(fd)
print("Done")
