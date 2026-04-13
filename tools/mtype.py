#!/usr/bin/env python3
"""Type text on MiSTer C64 via uinput virtual keyboard.

Usage (run on MiSTer):
  python3 /tmp/mtype.py "PRINT PEEK(53436)" enter
  python3 /tmp/mtype.py "10 A=PEEK(53436)" enter "20 PRINT A" enter "RUN" enter
  python3 /tmp/mtype.py f12    # F12 for OSD

Arguments are processed left to right:
  - Text strings: each character is typed
  - Special words: enter, f12, up, down, left, right, space, esc, etc.
  - "wait:N": pause N seconds
"""

import struct, os, time, fcntl, sys

UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_LEDBIT = 0x40045566
UI_SET_PHYS   = 0x4004556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_KEY = 1
EV_SYN = 0
EV_REP = 0x14
EV_LED = 0x11
EV_MSC = 0x04
KEY_LEFTSHIFT = 42

KEY_MAP = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '0':11,'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,
    ' ':57,'.':52,',':51,'/':53,'-':12,
    # C64-through-MiSTer remapping (PS/2 scancode → C64 matrix):
    # PC =/+ key (kc13) → C64 '+',  PC ;/: key (kc39) → C64 ':'
    # PC '/" key (kc40) → C64 ';',  PC F10 (kc68) → C64 '='
    '+':13, ':':39, ';':40, '=':68,
    '[':26,']':27,'\\':43,'`':41,
}
SHIFT_MAP = {
    # C64 shifted chars: shift + Linux keycode that maps to the C64 base key
    '(':10, ')':11, '$':5, '"':3, '!':2, '#':4, '%':6,
    '&':8, '<':51, '>':52, '?':53, '^':7, '_':12,
    # These C64 chars are on dedicated keys (no shift needed, use KEY_MAP above):
    # '@' → PC '[' (kc26) → C64 '@',  '*' → PC ']' (kc27) → C64 '*'
}
# Override: '@' and '*' are unshifted on C64 (mapped to PC [ and ] keys)
KEY_MAP['@'] = 26  # PC [ → C64 @
KEY_MAP['*'] = 27  # PC ] → C64 *
SPECIAL = {
    'enter':28,'return':28,'space':57,'backspace':14,'tab':15,
    'esc':1,'escape':1,'del':111,'delete':111,
    'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,
    'f7':65,'f8':66,'f9':67,'f10':68,'f11':87,'f12':88,
    'up':103,'down':108,'left':105,'right':106,
    'home':102,'end':107,'pgup':104,'pgdn':109,
}

def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    # EV_REP is critical: makes the kernel assign the 'kbd' handler,
    # which MiSTer requires for keyboard input processing.
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
    # Set a USB-like Phys string so MiSTer doesn't filter us out.
    # MiSTer skips devices with empty Phys (its own "MiSTer virtual input").
    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.9/input0\x00")
    except OSError:
        pass  # older kernels may not support UI_SET_PHYS
    name = b"USB Keyboard\x00" + b"\x00" * 67  # 80 bytes
    ids = struct.pack("HHHH", 3, 0x04d9, 0x0006, 0x0111)
    dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(6)  # wait for MiSTer to detect and open device (needs >3s after core reset)
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
        send_key(fd, KEY_MAP[ch.lower()])  # C64 doesn't need shift for uppercase
    elif ch in SHIFT_MAP:
        send_key(fd, SHIFT_MAP[ch], shift=True)
    else:
        print(f"unmapped: '{ch}'", file=sys.stderr)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mtype.py <text|special> [...]")
        return
    fd = create_uinput()
    for arg in sys.argv[1:]:
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
