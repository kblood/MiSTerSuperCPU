#!/usr/bin/env python3
"""Verify BRAM per-page stale hypothesis.
After MGL PRG load at $1000, flush ($D078) between PEEKs to force each
read to fall through to SDRAM. If SDRAM has the real data, PEEK after
flush returns $AD ($1001), else returns 0 (SDRAM write path broken).
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

    # Single batch: POKE flush, PEEK one addr, repeat.
    # Each POKE 53368,1 → cache_flush_sw → pgvalid cleared.
    # First PEEK after flush misses BRAM → SDRAM fill → correct byte.
    peek_cmds = [
        "'?PEEK(4096)'",                 # $1000 baseline (may be $DE or stale)
        "'POKE53368,1:?PEEK(4097)'",     # flush + read $1001 — should be $AD (173)
        "'POKE53368,1:?PEEK(4098)'",     # flush + read $1002 — should be $BE (190)
        "'POKE53368,1:?PEEK(4099)'",     # flush + read $1003 — should be $EF (239)
        "'POKE53368,1:?PEEK(4100)'",     # flush + read $1004 — $DE (222)
        "'POKE53368,1:?PEEK(4200)'",     # flush + read $1068 — $DE (222) pattern repeats
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"rc={rc}")
    time.sleep(3)
    md.cmd_screen(["test1000_flush.png"])
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
