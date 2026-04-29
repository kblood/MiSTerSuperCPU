#!/usr/bin/env python3
"""Match physical keyboard VID/PID and add EV_REP + LED bits."""
import struct, os, time, fcntl, sys, glob, subprocess

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_LEDBIT = 0x40045566
UI_SET_REPBIT = 0x40045567  # not standard but may help
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
EV_REP = 0x14
EV_LED = 0x11
EV_MSC = 0x04

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)

# Set event types
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)  # autorepeat - makes kernel add 'kbd' handler
fcntl.ioctl(fd, UI_SET_EVBIT, EV_LED)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)

# Set all key bits
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass

# Set LED bits (capslock, numlock, etc)
for led in range(5):
    try: fcntl.ioctl(fd, UI_SET_LEDBIT, led)
    except: pass

phys = b"usb-ffb40000.usb-1.9/input0" + b"\x00"
try:
    fcntl.ioctl(fd, UI_SET_PHYS, phys)
except OSError:
    pass

# Use 8BitDo keyboard VID/PID to match the physical keyboard
name = b"8BitDo Retro Keyboard" + b"\x00" * 59  # pad to 80
ids = struct.pack("HHHH", 3, 0x2dc8, 0x5200, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)

time.sleep(0.5)
devs = sorted(glob.glob("/dev/input/event*"))
our_dev = devs[-1]
print("our device: %s" % our_dev, flush=True)

# Check handlers
try:
    with open("/proc/bus/input/devices") as f:
        content = f.read()
    for block in content.split("\n\n"):
        if our_dev.split("/")[-1] in block:
            print("Device info:", flush=True)
            print(block, flush=True)
except:
    pass

print("waiting 8s for MiSTer...", flush=True)
time.sleep(8)

# Check if MiSTer opened it
try:
    result = subprocess.run(["fuser", our_dev], capture_output=True, text=True, timeout=3)
    print("fuser: %s" % result.stdout.strip(), flush=True)
except:
    pass

# Send key 'A' (keycode 30)
now = int(time.time())
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 1))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, 30, 0))
os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
print("sent key A", flush=True)

time.sleep(2)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("done", flush=True)
