#!/usr/bin/env python3
import fcntl, os, struct

EVIOCGRAB = 0x40044590

for i in range(7):
    path = f"/dev/input/event{i}"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
            print(f"{path}: NOT grabbed")
            fcntl.ioctl(fd, EVIOCGRAB, 0)
        except:
            print(f"{path}: GRABBED by another process")
        os.close(fd)
    except Exception as e:
        print(f"{path}: {e}")
