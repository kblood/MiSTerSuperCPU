#!/usr/bin/env python3
"""Test MGL PRG load at non-$0801 address to isolate SDRAM write path.
Load test_addr1000.prg ($1000 pattern DE AD BE EF) via MGL pipe.
BASIC won't auto-RUN it (RUN only runs from $0801, which remains empty),
so we stay at READY and can PEEK $1000+ to verify SDRAM contents.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/test_addr1000.mgl"

def ssh(c,t=10): return md.ssh(c,timeout=t)[0]

def main():
    print("[1] fresh MiSTer")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)

    print("[2] force FPGA reload")
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)

    print("[3] check UART")
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u.txt 2>/dev/null")
    cnt = ssh("wc -c /tmp/u.txt | awk '{print $1}'").strip()
    print(f"  UART: {cnt} bytes")

    print(f"[4] MGL: {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(15)

    md.cmd_screen(["test1000_post_mgl.png"])

    print("[5] mtype batch")
    peek_cmds = [
        "'?PEEK(57328);PEEK(57329);PEEK(57334);PEEK(57335)'",  # dl,inj,idx,flags
        "'?PEEK(57107);PEEK(57108);PEEK(57109)'",              # iowr count
        "'?PEEK(4096);PEEK(4097);PEEK(4098);PEEK(4099)'",      # $1000-$1003 should be DE AD BE EF = 222 173 190 239
        "'?PEEK(4100);PEEK(4101);PEEK(4102);PEEK(4103)'",      # $1004-$1007 same pattern
        "'?PEEK(2049);PEEK(2050)'",                             # $0801 should still be 0
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"  rc={rc}")

    time.sleep(3)
    md.cmd_screen(["test1000_peeks.png"])
    print("done")
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
