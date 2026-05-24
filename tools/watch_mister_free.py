#!/usr/bin/env python3
"""Monitor MiSTer CORENAME via paramiko. Emit one line on every change.
Exit 0 when CORENAME is empty, 'C64', or anything outside the Minimig/CDTV
family (i.e. cd32 agent has actually released)."""
import sys, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mister_debug import ssh

prev = None
while True:
    out, err, rc = ssh("cat /tmp/CORENAME 2>/dev/null")
    cur = (out or "").strip()
    if rc != 0 and not out:
        cur = "SSH_FAIL"
    if cur != prev:
        print(f"CORENAME=[{cur}]", flush=True)
        low = cur.lower()
        if cur == "" or low.startswith("c64"):
            print(f"FREE: MiSTer available now (CORENAME='{cur}')", flush=True)
            sys.exit(0)
        # cd32 family cores keep MiSTer busy
        if low.startswith("minimig") or low.startswith("cdtv") or low.startswith("amiga"):
            pass
        elif cur != "SSH_FAIL":
            print(f"UNKNOWN core=[{cur}] -- investigate before deploy", flush=True)
        prev = cur
    time.sleep(20)
