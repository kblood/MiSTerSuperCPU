#!/usr/bin/env python3
"""Test keyboard event injection with detailed debugging."""
import paramiko, time

HOST = '192.168.50.130'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

# Check kernel version
_, out, _ = c.exec_command('uname -a')
time.sleep(1)
print("Kernel:", out.read().decode().strip())

# Check sizeof input_event
_, out, _ = c.exec_command('python3 -c "import struct; print(struct.calcsize(\'llHHi\'), struct.calcsize(\'IIHHi\'))"')
time.sleep(1)
print("Event sizes (llHHi vs IIHHi):", out.read().decode().strip())

# Check if MiSTer has grabbed the device
test_script = r'''
import struct, os, time, fcntl

# Check EVIOCGRAB status
EVIOCGRAB = 0x40044590

# Try to open event1 for reading to see if it's grabbed
try:
    fd = os.open('/dev/input/event1', os.O_RDONLY | os.O_NONBLOCK)
    # Try to grab - if already grabbed, this fails
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 1)
        print("GRAB succeeded - device was NOT grabbed by MiSTer")
        fcntl.ioctl(fd, EVIOCGRAB, 0)  # ungrab
    except OSError as e:
        print(f"GRAB failed - device IS grabbed by MiSTer: {e}")
    os.close(fd)
except Exception as e:
    print(f"Open failed: {e}")

# Try writing a key event to event1
fd = os.open('/dev/input/event1', os.O_WRONLY)
EV_KEY = 1
EV_SYN = 0

# Use both struct formats to test
now = int(time.time())

# Send 'H' key (keycode 35)
print("Sending H key to event1...")
# press
n = os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 35, 1))
n += os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
# release
n += os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 35, 0))
n += os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
print(f"Wrote {n} bytes to event1")
os.close(fd)

# Also try writing to the uinput-created device
import fcntl

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass

# Match the physical keyboard's vendor/product/name
name = b"8BitDo 8BitDo Retro Keyboard\x00" + b"\x00" * 51  # 80 bytes
ids = struct.pack("HHHH", 3, 0x2dc8, 0x5200, 0x0111)  # BUS_USB, same VID/PID
phys = b"usb-ffb40000.usb-1.1/input1\x00"
try:
    fcntl.ioctl(fd, UI_SET_PHYS, phys)
except:
    pass
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)

print("Waiting 6s for uinput device detection...")
time.sleep(6)

# Send 'I' key (keycode 23) via uinput
print("Sending I key via uinput...")
now = int(time.time())
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 23, 1))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 23, 0))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
print("Sent I key")

time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("Done")
'''

sftp = c.open_sftp()
with sftp.open('/tmp/test_input.py', 'w') as f:
    f.write(test_script)
sftp.close()

_, out, err = c.exec_command('python3 /tmp/test_input.py 2>&1')
time.sleep(15)
print("\nTest output:")
print(out.read().decode())
if err.read():
    print("Errors:", err.read().decode())

c.close()
