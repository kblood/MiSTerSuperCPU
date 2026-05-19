#!/usr/bin/env python3
"""Hold a key down for N seconds via uinput virtual keyboard.

Usage: python3 /tmp/mhold.py <key> <seconds>
  python3 /tmp/mhold.py return 2.0
  python3 /tmp/mhold.py space 5
"""
import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_LEDBIT = 0x40045566
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1; EV_SYN = 0; EV_REP = 0x14; EV_LED = 0x11; EV_MSC = 0x04

SPECIAL = {
    'enter':28,'return':28,'space':57,'backspace':14,'tab':15,
    'esc':1,'escape':1,
    'up':103,'down':108,'left':105,'right':106,
    'home':102,'end':107,'pgup':104,'pgdn':109,
    'ctrl':29,'lctrl':29,'rctrl':97,
    'alt':56,'lalt':56,'ralt':100,
    'shift':42,'lshift':42,'rshift':54,
    'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,
    'f7':65,'f8':66,'f9':67,'f10':68,'f11':87,'f12':88,
}

def main():
    if len(sys.argv) < 3:
        print('Usage: mhold.py <key> <seconds>'); return
    key = sys.argv[1].lower()
    secs = float(sys.argv[2])
    code = SPECIAL.get(key)
    if code is None: print('unknown key', key); return
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_LED)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)
    for k in range(256):
        try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        except: pass
    for led in range(5):
        try: fcntl.ioctl(fd, UI_SET_LEDBIT, led)
        except: pass
    try: fcntl.ioctl(fd, UI_SET_PHYS, b'usb-ffb40000.usb-1.9/input0\x00')
    except OSError: pass
    name = b'USB Keyboard\x00' + b'\x00' * 67
    ids = struct.pack('HHHH', 3, 0x04d9, 0x0006, 0x0111)
    dev = name + ids + struct.pack('i', 0) + b'\x00' * (64*4*4)
    os.write(fd, dev); fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(6)
    now = int(time.time())
    os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
    print('holding %s for %.2fs' % (key, secs))
    time.sleep(secs)
    now = int(time.time())
    os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY); os.close(fd)

if __name__ == '__main__':
    main()
