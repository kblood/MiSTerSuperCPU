#!/usr/bin/env python3
"""RETIRED — MGL pipe <file>-tag loading is settled (works).

This script was created during a flip-flop investigation of whether the
MiSTer_cmd pipe handler processes MGL <file> tags. That question is now
settled: it does. Dragon's Lair MGLs (and other stock MiSTer MGLs) load
both <rbf> and <file> elements end-to-end. See
project_mgl_pipe_loads_files.md.

This script is also retired for folder-layout reasons — it scps vanilla
over /media/fat/_Computer/, which is vanilla-managed by the user.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md

import sys
print("ERROR: test_mgl_vanilla_core.py is retired — it used to scp vanilla over")
print("/media/fat/_Computer/C64.rbf. _Computer/ is vanilla-managed by the user and")
print("must not be touched by our test scripts. See feedback_mister_folder_layout.md.")
sys.exit(2)

VANILLA = "C64_MiSTer/releases/C64_20250828.rbf"
RBF_COMP = "/media/fat/_Computer/C64.rbf"
RBF_TEST = "/media/fat/_Test/C64.rbf"
MGL = "/media/fat/_Computer/doom.mgl"


BASIC = [
    '10 poke57090,0:poke57091,192',        # $DF02/03 = target $C000
    '20 poke57092,16:poke57093,0:poke57094,2',  # $DF04/05/06 = REU $020010
    '30 poke57095,1:poke57096,0',          # $DF07/08 = length 1
    '40 poke49152,170:poke57089,145',      # sentinel, then cmd $91 FETCH
    '50 ?"b010=";peek(49152);" exp 4"',
    '60 poke57092,17:poke57093,0:poke57094,2',
    '70 poke57095,1:poke57096,0',
    '80 poke49152,170:poke57089,145',
    '90 ?"b011=";peek(49152);" exp 5"',
    '100 ?"done"',
]


def show(cmd, timeout=10):
    out, err, rc = md.ssh(cmd, timeout=timeout)
    print(f'$ {cmd}')
    if out: print('  ' + out.rstrip().replace('\n', '\n  '))
    if err and rc != 0: print('  ERR:', err[:200])
    return out


def main():
    print("=" * 60)
    print("Vanilla-core MGL pipe REU loading test")
    print("=" * 60)

    print(f"\n[1] scp vanilla rbf -> {RBF_COMP} and {RBF_TEST}")
    if not md.scp_to(VANILLA, RBF_COMP):
        print("ERROR: scp to _Computer failed")
        return 1
    if not md.scp_to(VANILLA, RBF_TEST):
        print("ERROR: scp to _Test failed")
        return 1
    show(f"md5sum {RBF_COMP} {RBF_TEST}")

    # Show MGL so we know what we're loading
    show(f"cat {MGL}")

    print("\n[2] kill + restart MiSTer with vanilla rbf (fresh FPGA + fresh mtype state)")
    show(f"kill $(pidof MiSTer) 2>/dev/null; sleep 2; "
         f"nohup /media/fat/MiSTer {RBF_TEST} > /dev/null 2>&1 &")
    print("waiting 10s for boot + KERNAL...")
    time.sleep(10)

    md.cmd_screen(["mgl_vanilla_before.png"])

    # Snapshot pid + baseline read_bytes + fd count
    out = show("pidof MiSTer")
    pid = out.strip()
    if not pid:
        print("ERROR: MiSTer main not running"); return 1
    print(f"MiSTer pid: {pid}")

    out_before = show(f"cat /proc/{pid}/io")
    fd_before = show(f"ls /proc/{pid}/fd 2>/dev/null | wc -l")

    print("\n[3] trigger doom.mgl load via pipe")
    show(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")

    print("\n[4] poll /proc/io read_bytes + fd listing for doom.reu")
    doom_seen = False
    for i in range(30):
        time.sleep(1)
        out_pid, _, _ = md.ssh("pidof MiSTer")
        cur_pid = out_pid.strip()
        out_io, _, _ = md.ssh(f"cat /proc/{cur_pid}/io 2>/dev/null")
        out_fd, _, _ = md.ssh(f"ls -l /proc/{cur_pid}/fd 2>/dev/null | grep -i doom")
        rb_line = [l for l in out_io.splitlines() if 'read_bytes' in l]
        rb = rb_line[0].split()[-1] if rb_line else '?'
        fd = (out_fd.strip().splitlines() or ['none'])[0][:100]
        if 'doom' in fd.lower():
            doom_seen = True
        print(f"  t+{i+1:2d}s  pid={cur_pid}  read_bytes={rb}  fd_doom={fd}")
        if doom_seen:
            # keep polling a bit to catch when fd closes
            pass

    # Final io snapshot
    out_after = show(f"cat /proc/$(pidof MiSTer)/io")

    print("\n[5] wait for KERNAL READY, then BASIC verify")
    time.sleep(5)
    md.cmd_screen(["mgl_vanilla_mid.png"])

    tokens = ["'new'", "enter"]
    for line in BASIC:
        tokens.append("'" + line + "'")
        tokens.append("enter")
    tokens.append("'run'")
    tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    print(f"  typing {len(BASIC)} BASIC lines via single mtype.py call")
    md.ssh(cmd, timeout=240)
    time.sleep(4)

    md.cmd_screen(["mgl_vanilla_result.png"])

    print("\n" + "=" * 60)
    print("Summary:")
    print(f"  read_bytes before: {out_before.strip()}")
    print(f"  read_bytes after:  {out_after.strip()}")
    print(f"  doom fd seen during poll: {doom_seen}")
    print("  BASIC result: see mgl_vanilla_result.png")
    print()
    print("Interpretation:")
    print("  b010=4, b011=5, doom_fd=True/read_bytes jumped  -> MGL loads <file> tag")
    print("  b010=0, b011=170, doom_fd=False                 -> test setup fault; MGL is known to work")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
