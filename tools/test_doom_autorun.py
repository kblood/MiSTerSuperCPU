#!/usr/bin/env python3
"""End-to-end Doom via clean MGL path.

Uploads loader.prg to /media/fat/doom/ if not already there. Creates MGL
with REU + PRG entries. Loads via MGL pipe. Waits for auto-RUN to fire
loader.prg, which SuperCPU-sets up and REU-FETCHes to SuperRAM, then JML
$20:$0000.

Success = Doom visible on screen (title, intro, or gameplay).

NOTE: loader.prg may run for 30-60s given REU→SuperRAM copy work.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

RBF = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Test/doom_run.mgl"


def ssh(c, t=10):
    return md.ssh(c, timeout=t)[0]


def main():
    # Deploy rbf first (fix-enabled build)
    local_rbf = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "..", "C64_MiSTer", "output_files", "C64.rbf"))
    print(f"[0] deploy rbf {local_rbf}")
    if not md.scp_to(local_rbf, RBF):
        return 1

    # Check doom_run.mgl exists and points to right files
    print("[1] inspect MGL")
    print(ssh(f"cat {MGL}"))
    print(ssh("ls -la /media/fat/games/C64/doom.reu /media/fat/games/C64/loader.prg"))

    # Fresh MiSTer
    print("[2] kill+restart")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(5)
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    time.sleep(4)

    # Fire MGL
    print(f"[3] load_core {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")

    # Wait and screenshot multiple times
    print("[4] waiting + capturing screenshots")
    for i, wait in enumerate([10, 25, 45, 70]):
        remain = wait - (sum([10,25,45,70][:i]))
        time.sleep(remain)
        ssh("timeout 2 cat /dev/ttyS1 > /tmp/u_doom.txt")
        uart_tail = ssh("tail -1 /tmp/u_doom.txt")
        print(f"  t={wait}s uart: {uart_tail}")
        md.cmd_screen([f"C:/LLM/C64/MiSTerSuperCPU/doom_t{wait}s.png"])

    print("Done. Inspect doom_t*.png")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
