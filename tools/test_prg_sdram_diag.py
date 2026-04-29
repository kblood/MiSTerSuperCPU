#!/usr/bin/env python3
"""Diagnose whether MGL-triggered PRG load reaches SDRAM on SuperCPU core.

Reads $DF13-$DF15 (dbg_iowr_count) and $DF16-$DF1A (first-write capture)
in the same mtype batch as $0801-$0804 PEEKs. This isolates:
  - SDRAM write path  (dbg_iowr_count goes up with PRG bytes)
  - CPU read path     (PEEK $0801 returns real PRG byte vs 0)

If count > 65536 (erase alone) but PEEK returns 0 → read/write path mismatch.
If count == 65536 → io_cycle never fired for PRG bytes.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/asterix_scpu_abs.mgl"

def ssh(cmd, timeout=10):
    out, err, rc = md.ssh(cmd, timeout=timeout)
    return out

def main():
    print("[1] Kill + fresh MiSTer start")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2; rm -f /tmp/mt.log")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)
    print("  pid:", ssh("pidof MiSTer").strip())

    print("[2] Force FPGA reload via load_core pipe")
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)

    print("[3] UART check")
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u.txt 2>/dev/null")
    cnt = ssh("wc -c /tmp/u.txt | awk '{print $1}'").strip()
    print(f"  UART bytes: {cnt}")
    if cnt == "0":
        print("ABORT: UART dead")
        return 1

    print(f"[4] Trigger MGL: {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(20)

    md.cmd_screen(["sdram_diag_post_mgl.png"])

    print("[5] mtype batch: dbg counters + $0801 PEEK")
    peek_cmds = [
        "'?PEEK(57328);PEEK(57329);PEEK(57334);PEEK(57335)'",  # $DFF0 dl, $DFF1 inj, $DFF6 idx, $DFF7 flags
        "'?PEEK(57107);PEEK(57108);PEEK(57109)'",              # $DF13-$DF15 iowr_count
        "'?PEEK(57110);PEEK(57111);PEEK(57112);PEEK(57113);PEEK(57114)'",  # $DF16-$DF1A first addr/data
        "'?PEEK(43);PEEK(44);PEEK(45);PEEK(46)'",              # $2B/$2C TXT, $2D/$2E VAR
        "'?PEEK(2049);PEEK(2050);PEEK(2051);PEEK(2052)'",      # $0801-$0804 PRG
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"  mtype rc={rc}")

    time.sleep(3)
    md.cmd_screen(["sdram_diag_peeks.png"])
    print("[6] Done. See sdram_diag_peeks.png")
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
