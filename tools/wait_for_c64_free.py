#!/usr/bin/env python3
"""Poll /tmp/CORENAME on the shared MiSTer until the C64 slice is free to use.

Non-disruptive: only READS /tmp/CORENAME and /tmp/mister_session.lock. The
MiSTer at 192.168.50.130 is shared with the CD32/Minimig agent; this lets us
back off (per docs/agent-cooperation.md) and resume deploy automatically once
their core releases.

"Free" = CORENAME empty/absent OR == "C64". Anything else (e.g. an Amiga game
title like "CannonFodder-Z2fix", or "Minimig") means the other agent holds it.

Exit 0 when free (prints FREE), exit 2 on timeout. Uses a pre-connected socket
to dodge an intermittent Windows Winsock getaddrinfo race in paramiko.connect.
"""
import socket
import sys
import time

import paramiko

HOST, USER, PASS = "192.168.50.130", "root", "1"


def corename():
    sock = socket.create_connection((HOST, 22), timeout=10)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10, sock=sock)
    _, o, _ = c.exec_command("cat /tmp/CORENAME 2>/dev/null")
    name = o.read().decode(errors="replace").strip()
    c.close()
    return name


def main():
    interval = int(sys.argv[1]) if len(sys.argv) > 1 else 90
    max_min = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    deadline = time.time() + max_min * 60
    while time.time() < deadline:
        try:
            name = corename()
        except Exception as e:
            print("poll error: %s (retrying)" % e, flush=True)
            time.sleep(interval)
            continue
        if name == "" or name == "C64":
            print("FREE CORENAME=%r" % name, flush=True)
            return 0
        print("busy CORENAME=%r @ %s" % (name, time.strftime("%H:%M:%S")), flush=True)
        time.sleep(interval)
    print("TIMEOUT after %d min, last not-free" % max_min, flush=True)
    return 2


if __name__ == "__main__":
    sys.exit(main())
