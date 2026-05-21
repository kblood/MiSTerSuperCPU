#!/usr/bin/env python3
"""Persistent keyboard device for MiSTer with device detection monitoring.

Creates a uinput device and keeps it alive, monitoring whether MiSTer opens it.
"""

import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
EV_MSC = 4
EV_LED = 17
EV_REP = 20
KEY_LEFTSHIFT = 42
MSC_SCAN = 4

KEY_MAP = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '0':11,'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,
    ' ':57,'.':52,',':51,'/':53,'-':12,
    '+':13, ':':39, ';':40, '=':68,
    '[':26,']':27,'\\':43,'`':41,
}
SHIFT_MAP = {
    '(':10, ')':11, '$':5, '"':3, '!':2, '#':4, '%':6,
    '&':8, '<':51, '>':52, '?':53, '^':7, '_':12,
}
KEY_MAP['@'] = 26
KEY_MAP['*'] = 27
SPECIAL = {
    'enter':28,'return':28,'space':57,'backspace':14,'tab':15,
    'esc':1,'escape':1,'del':111,'delete':111,
    'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,
    'f7':65,'f8':66,'f9':67,'f10':68,'f11':87,'f12':88,
    'up':103,'down':108,'left':105,'right':106,
    'home':102,'end':107,'pgup':104,'pgdn':109,
}

UI_SET_RELBIT = 0x40045566
UI_SET_MSCBIT = 0x40045567
UI_SET_LEDBIT = 0x40045568
UI_SET_REPBIT = 0x4004556d

def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    # Set event types: KEY + MSC + LED + REP (like a real keyboard)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_LED)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)
    except:
        pass

    # Set specific key bits (not all 256 — mimic a real keyboard)
    for k in list(KEY_MAP.values()) + list(SHIFT_MAP.values()) + list(SPECIAL.values()) + [KEY_LEFTSHIFT, 29, 56, 97, 100, 125, 126]:
        try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        except: pass

    # MSC_SCAN for scan codes
    try:
        fcntl.ioctl(fd, UI_SET_MSCBIT, MSC_SCAN)
    except:
        pass

    # LED bits (capslock, numlock, etc)
    for led in range(5):
        try: fcntl.ioctl(fd, UI_SET_LEDBIT, led)
        except: pass

    # Set Phys to match a real USB keyboard port
    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.9/input0\x00")
    except OSError:
        pass

    # Use the 8BitDo's vendor/product ID (already recognized by MiSTer)
    name = b"USB Keyboard\x00" + b"\x00" * 67
    ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
    dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
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
    time.sleep(0.08)

def type_char(fd, ch):
    if ch in KEY_MAP:
        send_key(fd, KEY_MAP[ch])
    elif ch.lower() in KEY_MAP:
        send_key(fd, KEY_MAP[ch.lower()])
    elif ch in SHIFT_MAP:
        send_key(fd, SHIFT_MAP[ch], shift=True)
    else:
        print(f"unmapped: '{ch}'", file=sys.stderr)

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "test"

    if mode == "create":
        # Create device and keep it alive, write PID to file
        fd = create_uinput()
        with open("/tmp/mtype_fd", "w") as f:
            f.write(str(os.getpid()))
        print(f"Device created, PID={os.getpid()}, waiting for MiSTer to detect...")
        # Wait indefinitely
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            fcntl.ioctl(fd, UI_DEV_DESTROY)
            os.close(fd)

    elif mode == "test":
        # Create device, wait, check if MiSTer has it, send test key
        fd = create_uinput()
        print("Device created, waiting 8s for MiSTer...")
        for i in range(8):
            time.sleep(1)
            # Check if MiSTer opened our device
            try:
                fds = os.listdir("/proc/529/fd/")
                for fdn in fds:
                    try:
                        target = os.readlink(f"/proc/529/fd/{fdn}")
                        if "event" in target and target not in [
                            "/dev/input/event0", "/dev/input/event1",
                            "/dev/input/event2", "/dev/input/event3",
                            "/dev/input/event4", "/dev/input/event5",
                        ]:
                            print(f"  {i+1}s: MiSTer opened {target}!")
                    except:
                        pass
            except:
                pass

        print("Sending 'A' key...")
        send_key(fd, 30)
        time.sleep(1)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
        print("Done")

    elif mode == "type":
        # Create device, wait, type remaining args
        fd = create_uinput()
        print("Device created, waiting 8s...")
        time.sleep(8)

        for arg in sys.argv[2:]:
            low = arg.lower()
            if low in SPECIAL:
                send_key(fd, SPECIAL[low])
            elif low.startswith("wait:"):
                time.sleep(float(low[5:]))
            else:
                for ch in arg:
                    type_char(fd, ch)

        time.sleep(0.3)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)

if __name__ == '__main__':
    main()
