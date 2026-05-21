#!/usr/bin/env python3
"""Check what event devices MiSTer has open and test uinput detection."""
import paramiko, time

HOST = '192.168.50.130'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

# Find MiSTer PID
_, out, _ = c.exec_command('pidof MiSTer')
time.sleep(1)
pid = out.read().decode().strip()
print(f"MiSTer PID: {pid}")

# Check what event devices MiSTer has open
_, out, _ = c.exec_command(f'ls -la /proc/{pid}/fd/ 2>/dev/null | grep input')
time.sleep(1)
print(f"MiSTer open input devices:")
print(out.read().decode().strip())

# List all current input event devices
_, out, _ = c.exec_command('ls -la /dev/input/event*')
time.sleep(1)
print(f"\nCurrent event devices:")
print(out.read().decode().strip())

# Now create a uinput device and check if MiSTer opens it
test_script = r'''
import struct, os, time, fcntl, subprocess

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass

# Use a USB-like phys to avoid MiSTer filtering
try:
    fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.9/input0\x00")
except:
    pass

name = b"USB Keyboard\x00" + b"\x00" * 67  # 80 bytes
ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)

print("Created uinput device, checking...")
time.sleep(1)

# List event devices now
result = subprocess.run(['ls', '-la', '/dev/input/event*'], 
                       capture_output=True, text=True, shell=False)
# Use glob approach
import glob
events = sorted(glob.glob('/dev/input/event*'))
for e in events:
    try:
        with open(f'/sys/class/input/{os.path.basename(e)}/device/name') as f:
            name_str = f.read().strip()
        print(f"  {e}: {name_str}")
    except:
        print(f"  {e}: (no name)")

# Wait for MiSTer detection
print("\nWaiting 8 seconds for MiSTer to detect device...")
time.sleep(8)

# Check MiSTer's open fds
pid = subprocess.run(['pidof', 'MiSTer'], capture_output=True, text=True).stdout.strip()
result = subprocess.run(['ls', '-la', f'/proc/{pid}/fd/'], capture_output=True, text=True)
input_fds = [l for l in result.stdout.split('\n') if 'input' in l]
print(f"\nMiSTer (PID {pid}) input device fds:")
for l in input_fds:
    print(f"  {l}")

# Try sending a key
print("\nSending 'Z' key...")
now = int(time.time())
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 44, 1))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
time.sleep(0.05)
os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, 44, 0))
os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
print("Sent Z key")

time.sleep(1)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("Device destroyed")
'''

sftp = c.open_sftp()
with sftp.open('/tmp/test_uinput_detect.py', 'w') as f:
    f.write(test_script)
sftp.close()

_, out, err = c.exec_command('python3 /tmp/test_uinput_detect.py 2>&1')
time.sleep(20)
print("\nUinput test output:")
print(out.read().decode())

c.close()
