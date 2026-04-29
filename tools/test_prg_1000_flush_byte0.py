#!/usr/bin/env python3
"""Verify test_addr1000 $1000 via flush: does SDRAM have the first byte too?
If not — the $0801 bug is the SAME missing-first-byte bug, just masked at $1000
by the BRAM write-through (no-flush PEEK returns BRAM contents).
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/test_addr1000.mgl"

def ssh(c,t=10): return md.ssh(c,timeout=t)[0]

def main():
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(15)

    # flush THEN read $1000 — forces SDRAM path
    peek_cmds = [
        "'POKE53368,1:?PEEK(4096);PEEK(4097)'",  # $1000,$1001 after flush
        "'POKE53368,1:?PEEK(4098);PEEK(4099)'",  # $1002,$1003 after flush
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"rc={rc}")
    time.sleep(3)
    md.cmd_screen(["test1000_flush_byte0.png"])
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
