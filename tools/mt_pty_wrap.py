#!/usr/bin/env python3
"""Run MiSTer under a pty so stdout is line-buffered; dump all output to file."""
import pty, os, sys

LOG = "/tmp/mt_pty.log"
open(LOG, "wb").close()

def on_read(fd):
    data = os.read(fd, 4096)
    with open(LOG, "ab") as f:
        f.write(data)
        f.flush()
    return data

argv = ["/media/fat/MiSTer"] + sys.argv[1:]
pty.spawn(argv, on_read)
