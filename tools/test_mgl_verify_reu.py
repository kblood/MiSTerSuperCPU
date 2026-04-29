#!/usr/bin/env python3
"""RETIRED — MGL pipe REU loading verification.

The question this script was written to settle ("does the MiSTer_cmd pipe
handler process MGL <file> tags?") is now settled: it does. Dragon's Lair
MGLs (and other stock MiSTer MGLs) confirm both <rbf> and <file> elements
load end-to-end. See project_mgl_pipe_loads_files.md.

This script is also retired because its original implementation scp'd our
build into /media/fat/_Computer/, which is vanilla-only territory (see
feedback_mister_folder_layout.md). Retained as a failing stub to prevent
accidental re-runs.

Sequence:
 1. scp C64.rbf to /media/fat/_Test/C64.rbf
 2. ALSO cp to /media/fat/_Computer/C64.rbf (so MGL's <rbf>_Computer/C64</rbf>
    path resolves)
 3. kill MiSTer main + restart with the test rbf (fresh input state,
    clean FPGA boot)
 4. Wait for KERNAL READY
 5. Trigger doom.mgl via `echo load_core .../doom.mgl > /dev/MiSTer_cmd`
    This should trigger MGL parsing → file ioctl → REU SDRAM populated
 6. Wait 25s for 16MB transfer + KERNAL reboot
 7. SINGLE mtype.py call: BASIC program that
    (a) prints reu_ioctl_cnt (peek $DF09/$DF0A/$DF0B)
    (b) prints reu_ioctl_idx (peek $DF0C)
    (c) REU FETCH 1 byte from REU $020010 → $C000, prints PEEK(49152)
    (d) REU FETCH 1 byte from REU $020011 → $C000, prints PEEK(49152)
 8. Screenshot

doom.reu expected bytes:
    file[0x20010] = $04 (4)
    file[0x20011] = $05 (5)
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


# DO NOT write our build into /media/fat/_Computer/ — it must stay vanilla.
# See feedback_mister_folder_layout.md. This test script is RETIRED because
# its original implementation copied our modified rbf over _Computer/C64.rbf,
# which pollutes the vanilla-only folder. Retained only as a failing stub to
# prevent accidental re-runs.
import sys
print("ERROR: test_mgl_verify_reu.py is retired — it used to scp into /media/fat/_Computer/")
print("Use a test that writes ONLY to /media/fat/_Test/ and leaves _Computer/ untouched.")
sys.exit(2)

RBF_LOCAL = "C64_MiSTer/output_files/C64.rbf"
RBF_TEST  = "/media/fat/_Test/C64.rbf"
RBF_COMP  = "/media/fat/_Computer/C64.rbf"
MGL_PATH  = "/media/fat/_Computer/doom.mgl"


BASIC_LINES = [
    # line 10: print ioctl counter (24-bit)
    '10 a=peek(57097)+256*peek(57098)+65536*peek(57099)',
    '20 ?"cnt=";a;" idx=";peek(57100)',
    # line 30: REU register offsets (remember +1 offset: $DF01=cmd, not $DF00)
    #   57090/91 = $DF02/$DF03 (C64 target $C000)
    #   57092/93/94 = $DF04/$DF05/$DF06 (REU addr $020010)
    #   57095/96 = $DF07/$DF08 (length 1)
    #   57089 = $DF01 (command); $91 = FETCH immediate
    '30 poke57090,0:poke57091,192',
    '40 poke57092,16:poke57093,0:poke57094,2',
    '50 poke57095,1:poke57096,0',
    '60 poke49152,170:poke57089,145',
    '70 ?"b010=";peek(49152);" exp 4"',
    # second FETCH: REU $020011
    '80 poke57092,17:poke57093,0:poke57094,2',
    '90 poke57095,1:poke57096,0',
    '100 poke49152,170:poke57089,145',
    '110 ?"b011=";peek(49152);" exp 5"',
    '120 ?"done"',
]


def ssh_exit(cmd, timeout=10, label=None):
    if label:
        print(f"ssh: {label}")
    out, err, rc = md.ssh(cmd, timeout=timeout)
    if rc != 0 and err:
        print(f"  rc={rc} err={err[:200]}")
    elif out:
        head = out.strip().splitlines()[:4]
        for l in head:
            print(f"  {l}")
    return out, err, rc


def main():
    print("=" * 60)
    print("MGL pipe REU loading verification")
    print("=" * 60)

    # Phase 1: upload rbf
    print("\n[1/6] scp rbf to MiSTer...")
    if not md.scp_to(RBF_LOCAL, RBF_TEST):
        print("ERROR: scp to _Test failed")
        return 1
    ssh_exit(f"cp {RBF_TEST} {RBF_COMP}", label=f"cp -> {RBF_COMP}")

    # Sanity: show MGL contents
    ssh_exit(f"cat {MGL_PATH} | head -20", label=f"cat {MGL_PATH}")

    # Phase 2: kill + restart MiSTer main (fresh input state, fresh FPGA)
    print("\n[2/6] kill + restart MiSTer main for fresh mtype.py state...")
    ssh_exit("kill $(pidof MiSTer) 2>/dev/null; sleep 2; "
             f"nohup /media/fat/MiSTer {RBF_TEST} > /dev/null 2>&1 &",
             label="restart MiSTer")
    print("waiting 10s for MiSTer main + FPGA + KERNAL...")
    time.sleep(10)

    # Phase 3: pre-MGL baseline screenshot (optional)
    md.cmd_screen(["mgl_verify_before.png"])

    # Phase 4: trigger MGL load
    print("\n[3/6] trigger doom.mgl load via /dev/MiSTer_cmd pipe...")
    ssh_exit(f"echo 'load_core {MGL_PATH}' > /dev/MiSTer_cmd",
             label="load_core doom.mgl")
    print("waiting 25s for 16MB REU transfer + KERNAL ready...")
    time.sleep(25)

    # Phase 5: mid screenshot (should be at READY prompt after MGL reboot)
    md.cmd_screen(["mgl_verify_mid.png"])

    # Phase 6: single mtype.py batch - BASIC verifies ioctl_cnt + REU FETCH
    print("\n[4/6] type BASIC verification program (SINGLE mtype.py call)...")
    tokens = ["'new'", "enter"]
    for line in BASIC_LINES:
        tokens.append("'" + line + "'")
        tokens.append("enter")
    tokens.append("'run'")
    tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    print(f"  {len(BASIC_LINES)} BASIC lines, {len(tokens)} tokens")
    out, err, rc = md.ssh(cmd, timeout=240)
    if rc != 0:
        print(f"  mtype rc={rc} err={err[:200]}")
    time.sleep(4)

    # Phase 7: final screenshot with results
    print("\n[5/6] capture result screenshot...")
    md.cmd_screen(["mgl_verify_result.png"])

    print("\n[6/6] interpretation")
    print("  cnt>0, b010=4, b011=5  -> MGL WORKS (2026-04-13 confirmed)")
    print("  cnt=0, b010=0, b011=0  -> MGL did nothing")
    print("  cnt=0, b010=4, b011=5  -> stale SDRAM (verify by checking cnt)")
    print("  cnt>0, b010=0, b011=0  -> ioctl fired, wrong region (routing bug)")
    print("\nInspect mgl_verify_result.png for the BASIC output.")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
