#!/usr/bin/env python3
"""Navigate MiSTer OSD to set REU=16MB and load doom.reu into SDRAM.
Run on MiSTer: python3 /tmp/osd_load_reu.py
"""
import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0

KEY_MAP = {
    'down': 108, 'up': 103, 'enter': 28, 'esc': 1, 'f12': 88,
    'right': 106, 'left': 105,
}

def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in range(256):
        try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        except: pass
    try:
        phys = b"usb-ffb40000.usb-1.9/input0\x00"
        fcntl.ioctl(fd, UI_SET_PHYS, phys)
    except OSError:
        pass
    name = b"USB Keyboard\x00" + b"\x00" * 67
    ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
    dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def send_key(fd, name, hold=0.04):
    code = KEY_MAP[name]
    now = int(time.time())
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(hold)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.12)

def nav(fd, key, count=1, pause=0.15):
    for i in range(count):
        send_key(fd, key)
        time.sleep(pause)

# Create device and wait for MiSTer detection
fd = create_uinput()
print("Device created, waiting 8s for MiSTer...")
time.sleep(8)

# Close any open OSD
send_key(fd, "esc")
time.sleep(0.5)

# === PHASE 1: Set REU to 16MB ===
print("Phase 1: Setting REU to 16MB...")

# Open OSD
send_key(fd, "f12")
time.sleep(1.0)

# Navigate to Hardware page (position 6 from top)
# Menu: Mount#8(0), Mount#9(1), WP(2), [sep], F1(3), LoadREU(4), [sep], A&V(5), HW(6)
nav(fd, "down", 6)
time.sleep(0.3)

# Enter Hardware page
send_key(fd, "enter")
time.sleep(0.5)

# In Hardware page: GeoRAM(0), REU(1)
nav(fd, "down", 1)
time.sleep(0.2)

# Change REU: Disabled -> 512KB -> 2MB -> 16MB (3 rights)
nav(fd, "right", 3, pause=0.2)
time.sleep(0.3)

# Back to main menu
send_key(fd, "esc")
time.sleep(0.5)

# Close OSD
send_key(fd, "esc")
time.sleep(0.5)

# === PHASE 2: Load doom.reu ===
print("Phase 2: Loading doom.reu...")

# Open OSD again
send_key(fd, "f12")
time.sleep(1.0)

# Navigate to Load REU (position 4 from top)
nav(fd, "down", 4)
time.sleep(0.3)

# Enter to open file browser
send_key(fd, "enter")
time.sleep(2.0)

# In file browser: [..](0), aaa.reu(1), doom.reu(2)
nav(fd, "down", 2)
time.sleep(0.3)

# Select doom.reu
print("Selecting doom.reu...")
send_key(fd, "enter")

# Wait for 16MB transfer
print("Waiting for 16MB transfer...")
time.sleep(40)

fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("DONE")
