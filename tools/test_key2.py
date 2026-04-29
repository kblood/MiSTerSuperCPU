#!/usr/bin/env python3
"""Keep virtual keyboard alive and send a test key after MiSTer detects it."""
import struct, os, time, fcntl, sys, glob, subprocess

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass
phys = b"usb-ffb40000.usb-1.9/input0" + b"\x00"
try:
    fcntl.ioctl(fd, UI_SET_PHYS, phys)
except OSError:
    pass
name = b"USB Keyboard" + b"\x00" * 68
ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)

# Find which event device was created
time.sleep(0.5)
devs = sorted(glob.glob("/dev/input/event*"))
our_dev = devs[-1] if devs else "unknown"
print("our device: %s" % our_dev, flush=True)

# Wait for MiSTer to detect
print("waiting 8s for MiSTer to detect...", flush=True)
time.sleep(8)

# Check if MiSTer has it open
try:
    result = subprocess.run(["fuser", our_dev], capture_output=True, text=True, timeout=3)
    print("fuser %s: stdout=%s stderr=%s" % (our_dev, result.stdout.strip(), result.stderr.strip()), flush=True)
except:
    print("fuser check failed", flush=True)

# Send key 'A' (keycode 30)
now = int(time.time())
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 1))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 0))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
print("sent key A", flush=True)

# Keep alive a bit more
time.sleep(2)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("done", flush=True)
