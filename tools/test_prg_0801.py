#!/usr/bin/env python3
"""Is the 2-byte loss at $0801 asterix-specific or load-address-specific?
Load test_addr0801.prg (DE AD BE EF x64 at $0801) via MGL pipe.
BASIC will try to RUN it and crash/SYNTAX ERR, but SDRAM should hold the pattern.
PEEK $0801-$0807 to see whether first 2 bytes are zero or the pattern is intact.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/test_addr0801.mgl"

def ssh(c,t=10): return md.ssh(c,timeout=t)[0]

def main():
    print("[1] fresh MiSTer")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    print(f"[2] MGL: {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(15)
    md.cmd_screen(["test0801_post_mgl.png"])

    peek_cmds = [
        "'?PEEK(2049);PEEK(2050);PEEK(2051);PEEK(2052)'",  # $0801-$0804
        "'?PEEK(2053);PEEK(2054);PEEK(2055);PEEK(2056)'",  # $0805-$0808
        "'?PEEK(2100);PEEK(2101);PEEK(2102);PEEK(2103)'",  # $0834-$0837 well into payload
        "'POKE53368,1:?PEEK(2049);PEEK(2050)'",            # flush + re-read 0801/0802
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"rc={rc}")
    time.sleep(3)
    md.cmd_screen(["test0801_peeks.png"])
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
