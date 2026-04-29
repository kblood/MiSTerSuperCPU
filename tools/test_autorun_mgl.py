#!/usr/bin/env python3
"""Test PRG auto-RUN via MGL pipe end-to-end.

After successful auto-RUN of autorun_test.prg (which sets border=black,
background=green, infinite loop), the screen should show GREEN background.
Failure: remains blue with BASIC READY prompt, or garbage.

Reads $DFF0-$DFF7 diagnostic counters to pinpoint at which stage the
auto-RUN path breaks.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/autorun_test.mgl"


def ssh(c, t=10):
    return md.ssh(c, timeout=t)[0]


def main():
    # Ensure rbf is deployed first
    local_rbf = os.path.join(os.path.dirname(__file__), "..", "C64_MiSTer", "output_files", "C64.rbf")
    local_rbf = os.path.abspath(local_rbf)
    print(f"[0] deploy local rbf -> {RBF}")
    if not md.scp_to(local_rbf, RBF):
        print("  SCP failed")
        return 1

    print("[1] kill+restart MiSTer")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(5)
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    time.sleep(4)

    # Pre-MGL UART state
    print("[2] fresh UART sample")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u0.txt")
    print("  ", ssh("tail -1 /tmp/u0.txt"))

    print(f"[3] load_core {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    time.sleep(12)

    print("[4] post-MGL UART sample")
    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u1.txt")
    post_uart = ssh("tail -1 /tmp/u1.txt")
    print("  ", post_uart)

    # Screenshot AFTER MGL (before any PEEKs disturb state)
    md.cmd_screen(["C:/LLM/C64/MiSTerSuperCPU/autorun_postmgl.png"])

    # Upload mtype.py
    md.scp_to(
        "C:/LLM/C64/MiSTerSuperCPU/tools/mtype.py",
        "/tmp/mtype.py",
    )

    # Read diag counters in a single mtype batch — splits <80 chars per line
    print("[5] PEEK diagnostic counters")
    cmd = "python3 /tmp/mtype.py " + " ".join([
        repr("?peek(57328);peek(57329);peek(57330)"), "enter",
        repr("?peek(57331);peek(57332);peek(57333)"), "enter",
        repr("?peek(57334);peek(57335)"), "enter",
        repr("?peek(57342);peek(57343)"), "enter",
        repr("?peek(43);peek(44)"), "enter",
        repr("?peek(2049);peek(2050);peek(2051)"), "enter",
    ])
    out, err, rc = md.ssh(cmd, timeout=90)
    print(f"  mtype rc={rc}")
    time.sleep(4)
    md.cmd_screen(["C:/LLM/C64/MiSTerSuperCPU/autorun_peeks.png"])

    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
