#!/usr/bin/env python3
"""Type MVN test code using a single persistent uinput device."""
import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
KEY_LEFTSHIFT = 42

KEY_MAP = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '0':11,'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,
    ' ':57,'.':52,',':51,':':39,'(':10,')':11,  # ( = shift+9, ) = shift+0
    'enter':28,
}
SHIFT_CHARS = set(':()!@#$%^&*')

def setup_uinput():
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in range(256):
        try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        except: pass
    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.9/input0\x00")
    except OSError:
        pass
    name = b"USB Keyboard\x00" + b"\x00" * 67  # 80 bytes
    ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
    dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(3)  # wait for MiSTer to detect
    return fd

def send_key(fd, code, shift=False):
    now = int(time.time())
    if shift:
        os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, KEY_LEFTSHIFT, 1))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
        time.sleep(0.03)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.04)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    if shift:
        time.sleep(0.02)
        os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, KEY_LEFTSHIFT, 0))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.03)

def type_line(fd, text):
    for ch in text:
        c = ch.lower()
        if c in KEY_MAP:
            need_shift = ch in SHIFT_CHARS
            send_key(fd, KEY_MAP[c], shift=need_shift)
    # Enter
    send_key(fd, 28)
    time.sleep(0.8)

# MVN test code
code = [24,251,194,48,162,0,80,160,0,32,169,0,0,84,2,0,226,32,175,0,32,2,133,2,56,251,96]
base = 49152

lines = ['POKE20480,66']
for i in range(0, len(code), 4):
    chunk = code[i:min(i+4, len(code))]
    pokes = ':'.join(f'POKE{base+i+j},{chunk[j]}' for j in range(len(chunk)))
    lines.append(pokes)
lines.append('SYS49152:PRINTPEEK(2)')

fd = setup_uinput()
for line in lines:
    type_line(fd, line)
    print(f'OK: {line}')

fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print('Done')
