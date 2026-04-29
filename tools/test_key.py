#!/usr/bin/env python3
import struct, os, time, fcntl, sys, glob

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
print("opened uinput fd=%d" % fd)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass
phys = b"usb-ffb40000.usb-1.9/input0" + b"\x00"
try:
    fcntl.ioctl(fd, UI_SET_PHYS, phys)
    print("phys set OK")
except OSError as e:
    print("phys failed: %s" % e)
name = b"USB Keyboard" + b"\x00" * 68
ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
print("device created, waiting 6s...")
time.sleep(6)
devs = glob.glob("/dev/input/event*")
print("input devices:", devs)
# Type 'A' (keycode 30)
now = int(time.time())
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 1))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
time.sleep(0.04)
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 0))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
print("sent key A (keycode 30)")
time.sleep(0.3)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("done")
