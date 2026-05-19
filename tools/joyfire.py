#!/usr/bin/env python3
"""Continuous joystick autofire for breaking Doom's attract loop.

Usage on MiSTer:
  python3 /tmp/joyfire.py <seconds> [hz]

Defaults: 30 seconds, 10 Hz fire rate. Opens uinput gamepad once,
spams BTN_TRIGGER press/release at given rate, then destroys device.
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
BTN_JOYSTICK = 0x120

def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
    hz   = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    period = 1.0 / hz

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_JOYSTICK)
    fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_X)
    fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_Y)
    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.10/input0\x00")
    except OSError:
        pass
    # Spoof VID/PID of the real "usb gamepad" already on the bus so
    # MiSTer picks up its existing C64_input_0810_e501_v3.map mapping.
    name = b"usb gamepad           \x00" + b"\x00" * 57
    ids = struct.pack("HHHH", 3, 0x0810, 0xe501, 0x0110)
    absmin = [0]*64; absmax = [0]*64; absfuzz = [0]*64; absflat = [0]*64
    absmin[ABS_X] = 0; absmax[ABS_X] = 255; absflat[ABS_X] = 15
    absmin[ABS_Y] = 0; absmax[ABS_Y] = 255; absflat[ABS_Y] = 15
    abs_bytes = b''
    for arr in (absmax, absmin, absfuzz, absflat):
        for v in arr:
            abs_bytes += struct.pack("i", v)
    dev = name + ids + struct.pack("i", 0) + abs_bytes
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(6)  # MiSTer needs >3s to attach kbd/joy handlers

    # Center axes
    now = int(time.time())
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_X, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_ABS, ABS_Y, 128))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.1)

    end = time.time() + secs
    n = 0
    while time.time() < end:
        now = int(time.time())
        os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, BTN_JOYSTICK, 1))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
        time.sleep(period / 2.0)
        os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, BTN_JOYSTICK, 0))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
        time.sleep(period / 2.0)
        n += 1

    print("fired %d times in %.1fs (%.1f Hz)" % (n, secs, n/secs))
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)

if __name__ == '__main__':
    main()
