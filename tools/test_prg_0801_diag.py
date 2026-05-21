#!/usr/bin/env python3
"""Load test_addr0801.prg and dump diagnostic counters."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/test_addr0801.mgl"

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

    peek_cmds = [
        # per-PRG req_set_cnt lo/hi, req_cons_cnt lo/hi (DFF8-DFFB = 57336-57339)
        "'?PEEK(57336);PEEK(57337);PEEK(57338);PEEK(57339)'",
        # first write addr lo/hi + data, second data (DFFC-DFFF = 57340-57343)
        "'?PEEK(57340);PEEK(57341);PEEK(57342);PEEK(57343)'",
        # DFF6=sdram_0801_cnt, DFF7=sdram_0801_data (SDRAM-iface writes at $0801)
        "'?PEEK(57334);PEEK(57335)'",
        # DFF2-DFF5: PC lo/hi of last CPU write to $0801, cnt, data (post-dl/meminit)
        "'?PEEK(57330);PEEK(57331);PEEK(57332);PEEK(57333)'",
        # flushed SDRAM read at $0801-$0804
        "'POKE53368,1:?PEEK(2049);PEEK(2050);PEEK(2051);PEEK(2052)'",
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"rc={rc}")
    time.sleep(3)
    md.cmd_screen(["test0801_diag.png"])
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
