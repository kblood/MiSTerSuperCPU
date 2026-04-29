#!/usr/bin/env python3
"""Send keyboard input to MiSTer virtual input device.

Usage: python3 mister_type.py "PRINT PEEK(53436)" [enter]
       python3 mister_type.py run enter
       python3 mister_type.py f12

Runs locally on the MiSTer (copy via SCP first).
"""

import struct
import time
import sys
import os

# Linux input event structure: struct input_event { time, type, code, value }
# type=1 (EV_KEY), value=1 (press), value=0 (release)
EV_KEY = 1
EV_SYN = 0
SYN_REPORT = 0

# Linux key codes (from linux/input-event-codes.h)
KEY_MAP = {
    'a': 30, 'b': 48, 'c': 46, 'd': 32, 'e': 18, 'f': 33, 'g': 34,
    'h': 35, 'i': 23, 'j': 36, 'k': 37, 'l': 38, 'm': 50, 'n': 49,
    'o': 24, 'p': 25, 'q': 16, 'r': 19, 's': 31, 't': 20, 'u': 22,
    'v': 47, 'w': 17, 'x': 45, 'y': 21, 'z': 44,
    '0': 11, '1': 2, '2': 3, '3': 4, '4': 5, '5': 6, '6': 7,
    '7': 8, '8': 9, '9': 10,
    ' ': 57, '\n': 28, '.': 52, ',': 51, '/': 53, ';': 39, '\'': 40,
    '-': 12, '=': 13, '[': 26, ']': 27, '\\': 43, '`': 41,
}

# Special keys
SPECIAL_KEYS = {
    'enter': 28, 'return': 28, 'space': 57, 'backspace': 14,
    'tab': 15, 'esc': 1, 'escape': 1,
    'f1': 59, 'f2': 60, 'f3': 61, 'f4': 62, 'f5': 63, 'f6': 64,
    'f7': 65, 'f8': 66, 'f9': 67, 'f10': 68, 'f11': 87, 'f12': 88,
    'up': 103, 'down': 108, 'left': 105, 'right': 106,
    'lshift': 42, 'rshift': 54, 'lctrl': 29, 'rctrl': 97,
}

# Keys that need shift
SHIFT_MAP = {
    '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6',
    '&': '7', '*': '8', '(': '9', ')': '0', '_': '-', '+': '=',
    '{': '[', '}': ']', '|': '\\', ':': ';', '"': '\'', '<': ',',
    '>': '.', '?': '/',
}

INPUT_DEV = '/dev/input/event2'

def write_event(fd, etype, code, value):
    """Write a single input event."""
    # struct timeval { long tv_sec; long tv_usec; }
    # struct input_event { struct timeval time; __u16 type; __u16 code; __s32 value; }
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1000000)
    event = struct.pack('llHHi', sec, usec, etype, code, value)
    os.write(fd, event)

def send_key(fd, keycode, shift=False):
    """Send a key press and release."""
    if shift:
        write_event(fd, EV_KEY, 42, 1)  # LSHIFT press
        write_event(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.02)

    write_event(fd, EV_KEY, keycode, 1)  # key press
    write_event(fd, EV_SYN, SYN_REPORT, 0)
    time.sleep(0.03)

    write_event(fd, EV_KEY, keycode, 0)  # key release
    write_event(fd, EV_SYN, SYN_REPORT, 0)

    if shift:
        time.sleep(0.02)
        write_event(fd, EV_KEY, 42, 0)  # LSHIFT release
        write_event(fd, EV_SYN, SYN_REPORT, 0)

    time.sleep(0.05)

def type_text(fd, text):
    """Type a string of text."""
    for ch in text:
        if ch in KEY_MAP:
            send_key(fd, KEY_MAP[ch])
        elif ch.lower() in KEY_MAP:
            # Uppercase letter → shift + lowercase
            send_key(fd, KEY_MAP[ch.lower()], shift=True)
        elif ch in SHIFT_MAP:
            base = SHIFT_MAP[ch]
            send_key(fd, KEY_MAP[base], shift=True)
        else:
            print(f"Warning: unmapped character '{ch}'", file=sys.stderr)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mister_type.py <text|special_key> [...]")
        print("  text: typed as keyboard input")
        print("  enter/f12/up/down/etc: special keys")
        return

    fd = os.open(INPUT_DEV, os.O_WRONLY)

    for arg in sys.argv[1:]:
        lower = arg.lower()
        if lower in SPECIAL_KEYS:
            send_key(fd, SPECIAL_KEYS[lower])
        else:
            type_text(fd, arg)

    os.close(fd)

if __name__ == '__main__':
    main()
