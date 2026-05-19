#!/usr/bin/env python3
"""Inject joystick events on MiSTer C64 via uinput virtual gamepad.

Usage (run on MiSTer):
  python3 /tmp/jtype.py fire             # tap fire button
  python3 /tmp/jtype.py up               # tap up direction
  python3 /tmp/jtype.py down fire        # down then fire
  python3 /tmp/jtype.py hold:fire:500    # hold fire 500 ms

Arguments are processed left to right:
  - Direction words: up/down/left/right (250 ms tap)
  - Buttons: fire/btn2/btn3
  - "hold:KEY:MS": hold key for MS milliseconds
  - "wait:N": pause N seconds (float)
"""

import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
EV_ABS = 3

ABS_X = 0x00
ABS_Y = 0x01

BTN_JOYSTICK = 0x120  # BTN_TRIGGER
BTN_THUMB    = 0x121
BTN_THUMB2   = 0x122
BTN_TOP      = 0x123
BTN_SOUTH    = 0x130  # gamepad A
BTN_EAST     = 0x131  # gamepad B
BTN_NORTH    = 0x133  # gamepad Y
BTN_WEST     = 0x134  # gamepad X

BUTTONS = {
    'fire':  BTN_JOYSTICK,
    'btn2':  BTN_THUMB,
    'btn3':  BTN_THUMB2,
    'btn4':  BTN_TOP,
    'a':     BTN_SOUTH,
    'b':     BTN_EAST,
    'x':     BTN_WEST,
    'y':     BTN_NORTH,
}

def create_joy():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in BUTTONS.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_X)
    fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_Y)
    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.10/input0\x00")
    except OSError:
        pass
    # Match VID/PID of the real "usb gamepad" so MiSTer reuses its C64 map.
    name = b"usb gamepad           \x00" + b"\x00" * 57  # 80 bytes
    ids = struct.pack("HHHH", 3, 0x0810, 0xe501, 0x0110)
    absmin = [0]*64; absmax = [0]*64; absfuzz = [0]*64; absflat = [0]*64
    # ABS_X / ABS_Y centered at 128, range 0..255 (PC analog joystick)
    absmin[ABS_X] = 0;   absmax[ABS_X] = 255; absflat[ABS_X] = 15
    absmin[ABS_Y] = 0;   absmax[ABS_Y] = 255; absflat[ABS_Y] = 15
    abs_bytes = b''
    for arr in (absmax, absmin, absfuzz, absflat):
        for v in arr:
            abs_bytes += struct.pack("i", v)
    dev = name + ids + struct.pack("i", 0) + abs_bytes
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(6)  # wait for MiSTer to detect device
    # center axes
    now = int(time.time())
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_X, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_Y, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.05)
    return fd

def press_button(fd, code, hold_ms=80):
    now = int(time.time())
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(hold_ms / 1000.0)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.08)

def push_dir(fd, dx, dy, hold_ms=200):
    now = int(time.time())
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_X, 128 + dx))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_Y, 128 + dy))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(hold_ms / 1000.0)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_X, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_Y, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.08)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 jtype.py <button|direction|hold:k:ms|wait:s> [...]")
        return
    fd = create_joy()
    for arg in sys.argv[1:]:
        low = arg.lower()
        if low == 'up':       push_dir(fd, 0, -127)
        elif low == 'down':   push_dir(fd, 0,  127)
        elif low == 'left':   push_dir(fd, -127, 0)
        elif low == 'right':  push_dir(fd,  127, 0)
        elif low.startswith('hold:'):
            parts = low.split(':')
            key = parts[1]; ms = int(parts[2])
            if key in BUTTONS: press_button(fd, BUTTONS[key], hold_ms=ms)
            elif key == 'up':    push_dir(fd, 0, -127, hold_ms=ms)
            elif key == 'down':  push_dir(fd, 0,  127, hold_ms=ms)
            elif key == 'left':  push_dir(fd, -127, 0, hold_ms=ms)
            elif key == 'right': push_dir(fd,  127, 0, hold_ms=ms)
            else: print("unknown hold key: %s" % key, file=sys.stderr)
        elif low.startswith('wait:'):
            time.sleep(float(low[5:]))
        elif low in BUTTONS:
            press_button(fd, BUTTONS[low])
        else:
            print("unmapped: %s" % low, file=sys.stderr)
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)

if __name__ == '__main__':
    main()
