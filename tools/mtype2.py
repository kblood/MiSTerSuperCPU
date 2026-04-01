#!/usr/bin/env python3
"""Virtual keyboard for MiSTer C64 — daemon + client model.

Daemon mode:  python3 mtype2.py daemon &
Client mode:  python3 mtype2.py "POKE49152,120" enter
              python3 mtype2.py f12

The daemon creates a persistent uinput device that MiSTer keeps open.
Client sends key names via a FIFO pipe at /tmp/mtype2.pipe.
"""

import struct, os, time, fcntl, sys, select

UI_SET_EVBIT   = 0x40045564
UI_SET_KEYBIT  = 0x40045565
UI_SET_PHYS    = 0x4004556C
UI_SET_MSCBIT  = 0x40045567
UI_SET_LEDBIT  = 0x40045568
UI_DEV_CREATE  = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0
EV_KEY = 1
EV_MSC = 4
EV_LED = 17
EV_REP = 20
MSC_SCAN = 4
KEY_LEFTSHIFT = 42

KEY_MAP = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '0':11,'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,
    ' ':57,'.':52,',':51,'/':53,'-':12,
    '+':13,':':39,';':40,'=':68,
    '[':26,']':27,'\\':43,'`':41,
}
SHIFT_MAP = {
    '(':10,')':11,'$':5,'"':3,'!':2,'#':4,'%':6,
    '&':8,'<':51,'>':52,'?':53,'^':7,'_':12,
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

PIPE_PATH = "/tmp/mtype2.pipe"
PID_PATH = "/tmp/mtype2.pid"

def create_device():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    # Event types
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_MSC)
    try: fcntl.ioctl(fd, UI_SET_EVBIT, EV_LED)
    except: pass
    try: fcntl.ioctl(fd, UI_SET_EVBIT, EV_REP)
    except: pass

    # Register all standard keyboard keys
    for k in range(1, 128):
        try: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        except: pass

    try: fcntl.ioctl(fd, UI_SET_MSCBIT, MSC_SCAN)
    except: pass

    for led in range(5):
        try: fcntl.ioctl(fd, UI_SET_LEDBIT, led)
        except: pass

    try:
        fcntl.ioctl(fd, UI_SET_PHYS, b"usb-ffb40000.usb-1.9/input0\x00")
    except: pass

    # Match real keyboard vendor/product
    name = b"8BitDo 8BitDo Retro Keyboard\x00" + b"\x00" * 51
    ids = struct.pack("HHHH", 3, 0x2dc8, 0x5200, 0x0111)
    dev = name + ids + struct.pack("i", 0) + b"\x00" * (64*4*4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def send_key(fd, code, shift=False):
    now = int(time.time())
    if shift:
        os.write(fd, struct.pack("IIHHi", now, 0, EV_MSC, MSC_SCAN, KEY_LEFTSHIFT))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, KEY_LEFTSHIFT, 1))
        os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
        time.sleep(0.03)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_MSC, MSC_SCAN, code))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 1))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    time.sleep(0.04)
    os.write(fd, struct.pack("IIHHi", now, 0, EV_MSC, MSC_SCAN, code))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_KEY, code, 0))
    os.write(fd, struct.pack("IIHHi", now, 0, EV_SYN, 0, 0))
    if shift:
        time.sleep(0.02)
        os.write(fd, struct.pack("IIHHi", now, 0, EV_MSC, MSC_SCAN, KEY_LEFTSHIFT))
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

def process_args(fd, args):
    for arg in args:
        low = arg.lower()
        if low in SPECIAL:
            send_key(fd, SPECIAL[low])
        elif low.startswith("wait:"):
            time.sleep(float(low[5:]))
        else:
            for ch in arg:
                type_char(fd, ch)
    time.sleep(0.1)

def daemon_mode():
    # Kill existing daemon
    try:
        with open(PID_PATH) as f:
            old_pid = int(f.read().strip())
        os.kill(old_pid, 9)
        time.sleep(0.5)
    except:
        pass

    # Remove old pipe
    try: os.unlink(PIPE_PATH)
    except: pass

    fd = create_device()
    print(f"Device created, PID={os.getpid()}")

    # Save PID
    with open(PID_PATH, "w") as f:
        f.write(str(os.getpid()))

    # Create FIFO
    os.mkfifo(PIPE_PATH)
    os.chmod(PIPE_PATH, 0o666)
    print(f"Listening on {PIPE_PATH}")
    sys.stdout.flush()

    try:
        while True:
            # Open FIFO for reading (blocks until a writer connects)
            pipe_fd = os.open(PIPE_PATH, os.O_RDONLY)
            data = b""
            while True:
                chunk = os.read(pipe_fd, 4096)
                if not chunk:
                    break
                data += chunk
            os.close(pipe_fd)

            if data:
                line = data.decode("utf-8", errors="replace").strip()
                if line == "QUIT":
                    break
                args = line.split()
                if args:
                    process_args(fd, args)
                    print(f"Processed: {args}")
                    sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
        try: os.unlink(PIPE_PATH)
        except: pass
        try: os.unlink(PID_PATH)
        except: pass
        print("Daemon stopped")

def client_mode(args):
    if not os.path.exists(PIPE_PATH):
        print("Daemon not running! Start with: python3 mtype2.py daemon &")
        sys.exit(1)
    msg = " ".join(args) + "\n"
    fd = os.open(PIPE_PATH, os.O_WRONLY)
    os.write(fd, msg.encode())
    os.close(fd)

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 mtype2.py daemon &   # Start persistent device")
        print("  python3 mtype2.py <keys>     # Send keys (daemon must be running)")
        return

    if sys.argv[1] == "daemon":
        daemon_mode()
    else:
        client_mode(sys.argv[1:])

if __name__ == "__main__":
    main()
