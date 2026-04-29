#!/usr/bin/env python3
"""Inject keyboard events directly via evdev on MiSTer.
Run on MiSTer: python3 /tmp/evtype.py SYS49152 enter
"""
import struct, os, time, sys

EV_KEY = 1
EV_SYN = 0
KEY_LEFTSHIFT = 42

KEY_MAP = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '0':11,'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,
    ' ':57,'.':52,',':51,'/':53,'-':12,
    '+':13, ':':39, ';':40, '=':68,
    '[':26,']':27,'@':26,'*':27,
}
SHIFT_MAP = {
    '(':10, ')':11, '$':5, '"':3, '!':2, '#':4, '%':6,
    '&':8, '<':51, '>':52, '?':53, '^':7, '_':12,
}
SPECIAL = {
    'enter':28,'return':28,'space':57,'backspace':14,'tab':15,
    'esc':1,'escape':1,'del':111,'delete':111,
    'up':103,'down':108,'left':105,'right':106,
    'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,
    'f7':65,'f8':66,'f9':67,'f10':68,'f11':87,'f12':88,
    'home':102,'end':107,'pgup':104,'pgdn':109,
}

def find_keyboard():
    """Find the real keyboard event device (not mouse/gamepad interface).
    Looks for the event device with 'kbd' in its handlers."""
    for i in range(10):
        path = "/dev/input/event" + str(i)
        try:
            handlers_path = "/sys/class/input/event" + str(i) + "/device/handlers"
            name_path = "/sys/class/input/event" + str(i) + "/device/name"
            with open(handlers_path) as f:
                handlers = f.read().strip()
            with open(name_path) as f:
                name = f.read().strip()
            if 'kbd' in handlers:
                return path, name
        except Exception:
            continue
    # Fallback: event1 is usually the keyboard on MiSTer
    return "/dev/input/event1", "fallback"

def send_key(fd, code, shift=False):
    now = int(time.time())
    if shift:
        os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, KEY_LEFTSHIFT, 1))
        os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
        time.sleep(0.03)
    os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
    time.sleep(0.04)
    os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
    if shift:
        time.sleep(0.02)
        os.write(fd, struct.pack('IIHHi', now, 0, EV_KEY, KEY_LEFTSHIFT, 0))
        os.write(fd, struct.pack('IIHHi', now, 0, EV_SYN, 0, 0))
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

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 evtype.py <text|special> [...]")
        sys.exit(1)
    
    dev, name = find_keyboard()
    print(f"Using: {dev} ({name})", file=sys.stderr)
    fd = os.open(dev, os.O_WRONLY)
    
    for arg in sys.argv[1:]:
        low = arg.lower()
        if low in SPECIAL:
            send_key(fd, SPECIAL[low])
        elif low.startswith("wait:"):
            time.sleep(float(low[5:]))
        else:
            for ch in arg:
                type_char(fd, ch)
    
    time.sleep(0.1)
    os.close(fd)
    print("done", file=sys.stderr)
