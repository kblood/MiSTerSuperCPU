#!/usr/bin/env python3
"""Enhanced uinput with full keyboard capabilities matching real keyboard.
Also tests IRQ vector hook approach for keyboard-free PRG execution."""
import paramiko, time, struct

HOST = '192.168.50.130'

SCRIPT = r'''
import struct, os, time, fcntl

# Constants
UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_LEDBIT = 0x40045566
UI_SET_MSCBIT = 0x40045568
UI_SET_REPBIT = 0x40045569
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0x00
EV_KEY = 0x01
EV_MSC = 0x04
EV_LED = 0x11
EV_REP = 0x14

MSC_SCAN = 0x04
LED_NUML = 0x00
LED_CAPSL = 0x01
LED_SCROLLL = 0x02
REP_DELAY = 0x00
REP_PERIOD = 0x01

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)

# Set EV bits to match real keyboard: EV_SYN + EV_KEY + EV_MSC + EV_LED + EV_REP
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_LED)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)

# Set all key bits (0-255)
for k in range(256):
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    except: pass

# Set MSC bits
try: fcntl.ioctl(fd, UI_SET_MSCBIT, MSC_SCAN)
except: pass

# Set LED bits
for led in [LED_NUML, LED_CAPSL, LED_SCROLLL]:
    try: fcntl.ioctl(fd, UI_SET_LEDBIT, led)
    except: pass

# Set REP bits
for rep in [REP_DELAY, REP_PERIOD]:
    try: fcntl.ioctl(fd, UI_SET_REPBIT, rep)
    except: pass

# Match 8BitDo keyboard VID/PID
try:
    fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.3/input0\x00")
except:
    pass

# uinput_user_dev: name[80] + id(bus,vendor,product,version) + ff_effects_max + absmax[64] + absmin[64] + absfuzz[64] + absflat[64]
name = b"8BitDo 8BitDo Retro Keyboard\x00" + b"\x00" * 51  # 80 bytes total
# bus=3(USB), vendor=0x2dc8(8BitDo), product=0x0170, version=0x0111
ids = struct.pack("HHHH", 3, 0x2dc8, 0x0170, 0x0111)
rest = struct.pack("i", 0) + b"\x00" * (64*4*4)
os.write(fd, name + ids + rest)
fcntl.ioctl(fd, UI_DEV_CREATE)

print("Created full-capability uinput keyboard (matching 8BitDo)")
print("Waiting 10s for MiSTer detection...")
time.sleep(10)

# Check detection
import subprocess, glob
pid = subprocess.run(['pidof', 'MiSTer'], capture_output=True, text=True).stdout.strip()
result = subprocess.run(['ls', '-la', f'/proc/{pid}/fd/'], capture_output=True, text=True)
input_fds = [l for l in result.stdout.split('\n') if 'input' in l]
print(f"MiSTer input fds: {len(input_fds)}")
for l in input_fds:
    print(f"  {l.split('-> ')[-1] if '-> ' in l else l}")

def send_key(fd, keycode, scancode=None):
    """Send a key press with optional MSC_SCAN, like a real keyboard."""
    now = int(time.time())
    usec = int((time.time() % 1) * 1000000)
    
    # Key down with MSC_SCAN (like real HID keyboard)
    if scancode is not None:
        os.write(fd, struct.pack('IIHHi', now, usec, EV_MSC, MSC_SCAN, scancode))
    os.write(fd, struct.pack('IIHHi', now, usec, EV_KEY, keycode, 1))
    os.write(fd, struct.pack('IIHHi', now, usec, EV_SYN, 0, 0))
    
    time.sleep(0.08)  # Hold key for 80ms
    
    # Key up
    now2 = int(time.time())
    usec2 = int((time.time() % 1) * 1000000)
    if scancode is not None:
        os.write(fd, struct.pack('IIHHi', now2, usec2, EV_MSC, MSC_SCAN, scancode))
    os.write(fd, struct.pack('IIHHi', now2, usec2, EV_KEY, keycode, 0))
    os.write(fd, struct.pack('IIHHi', now2, usec2, EV_SYN, 0, 0))
    
    time.sleep(0.05)  # Inter-key delay

# Type "A" to test
# KEY_A = 30, HID scancode for A = 0x70004
print("Sending 'A' key with MSC_SCAN...")
send_key(fd, 30, 0x70004)

print("Waiting 3s...")
time.sleep(3)

# Type another "B" 
print("Sending 'B' key with MSC_SCAN...")
send_key(fd, 48, 0x70005)

print("Waiting 3s more...")
time.sleep(3)

print("Test complete. Device still alive for screenshot check.")
# Keep device alive for a bit
time.sleep(5)

fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("Device destroyed")
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username='root', password='1', timeout=10)

sftp = c.open_sftp()
with sftp.open('/tmp/test_full_kb.py', 'w') as f:
    f.write(SCRIPT)
sftp.close()

print("Running enhanced keyboard test...")
_, out, err = c.exec_command('python3 /tmp/test_full_kb.py 2>&1', timeout=45)
# Read output as it comes
time.sleep(35)
output = out.read().decode()
print(output)

err_text = err.read().decode()
if err_text:
    print(f"STDERR: {err_text}")

c.close()
