#!/usr/bin/env python3
"""Fully automated PRG-via-MGL load test on the SuperCPU core.

Strategy:
  1. Kill+restart MiSTer on _Test rbf.
  2. Force FPGA reprogram via load_core pipe (ensures our newest rbf is on FPGA).
  3. Verify UART is streaming (proves our build is live).
  4. Trigger asterix_scpu.mgl via /dev/MiSTer_cmd pipe.
  5. Wait long enough for MGL sequence + potential RUN type.
  6. Single mtype.py batch: PEEK the $DFF0-$DFF7 counters and $2B/$2C BASIC pointer + $0801 byte.
  7. Screenshot and scrape the printed numbers.

If the PRG auto-ran (RUN typed successfully), we won't be at READY and the PEEKs
won't print. The screenshot will still show whatever's on-screen.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF    = "/media/fat/_Test/C64.rbf"
MGL    = "/media/fat/_Test/asterix_scpu_abs.mgl"


def ssh(cmd, timeout=10, quiet=True):
    out, err, rc = md.ssh(cmd, timeout=timeout)
    if not quiet:
        print(f"$ {cmd}")
        if out.strip(): print("  " + out.rstrip().replace("\n", "\n  "))
    return out


def main():
    print("=" * 64)
    print("Automated PRG-via-MGL test on SuperCPU core (_Test/C64.rbf)")
    print("=" * 64)

    print("\n[1] Kill MiSTer, fresh restart on _Test rbf")
    ssh(f"kill $(pidof MiSTer) 2>/dev/null; sleep 2; rm -f /tmp/mt.log")
    ssh(f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(6)
    print("  pid:", ssh("pidof MiSTer").strip())

    print(f"\n[2] Force FPGA reprogram via load_core pipe")
    ssh(f"echo 'load_core {RBF}' > /dev/MiSTer_cmd")
    time.sleep(7)  # fpga_load_rbf + app_restart + KERNAL boot

    print("\n[3] Verify UART streaming (proves SuperCPU build is live)")
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u.txt 2>/dev/null")
    cnt = ssh("wc -c /tmp/u.txt | awk '{print $1}'").strip()
    first = ssh("head -1 /tmp/u.txt").strip()
    print(f"  UART bytes in 2s: {cnt}")
    print(f"  first line: {first[:120]}")
    if cnt == "0":
        print("  ABORT: UART dead, SuperCPU build not on FPGA")
        return 1

    md.cmd_screen(["mgl_test_pre_kernel.png"])

    print(f"\n[4] Trigger MGL via pipe: {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")

    print("\n[5] Wait 20s for MGL sequence (reset + KERNAL boot + PRG stream + auto-run)")
    time.sleep(20)

    md.cmd_screen(["mgl_test_post_mgl.png"])

    # Check UART state: if CPU is running the PRG, PC will be in $0800+ range
    # If CPU is at BASIC READY, PC will be in $E5xx area (KERNAL GETIN)
    print("\n[6] Capture UART tail to see where CPU is")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u2.txt 2>/dev/null")
    tail = ssh("tail -3 /tmp/u2.txt").strip()
    print(f"  last UART lines:\n  {tail}")

    print("\n[7] mtype.py batch: PEEK diagnostics")
    # Lines to type, each followed by enter
    peek_cmds = [
        "'?peek(57328);peek(57329);peek(57330);peek(57331)'",
        "'?peek(57332);peek(57333)'",
        "'?peek(57334);peek(57335)'",
        "'?peek(57342);peek(57343)'",
        "'?peek(43);peek(44)'",
        "'?peek(2049);peek(2050);peek(2051);peek(2052)'",
    ]
    tokens = []
    for line in peek_cmds:
        tokens.append(line)
        tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"  mtype rc={rc}")
    if err.strip():
        print(f"  err: {err[:200]}")

    time.sleep(3)
    md.cmd_screen(["mgl_test_peeks.png"])

    print("\n[8] Done. Inspect:")
    print("  - mgl_test_pre_kernel.png  (core boot state)")
    print("  - mgl_test_post_mgl.png    (after MGL sequence)")
    print("  - mgl_test_peeks.png       (PEEK results)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
