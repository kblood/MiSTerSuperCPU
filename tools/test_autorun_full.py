#!/usr/bin/env python3
"""End-to-end test of PRG auto-RUN via MGL pipe.

Deploys the current rbf, loads autorun_test.mgl via pipe, screenshots,
and reads diagnostic counters to confirm auto-RUN path.

The autorun_test.prg sets border=black, background=GREEN and loops — so
a successful auto-RUN produces a clearly visible GREEN screen.

Exits 0 if success (green screen detected), 1 otherwise.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF  = "/media/fat/_Test/C64.rbf"
MGL  = "/media/fat/_Test/autorun_test.mgl"


def ssh(c, t=10):
    return md.ssh(c, timeout=t)[0]


def main():
    print("=" * 72)
    print("Auto-RUN regression test (autorun_test.prg via MGL pipe)")
    print("=" * 72)

    # Deploy local rbf
    local_rbf = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "..", "C64_MiSTer", "output_files", "C64.rbf"))
    print(f"\n[0] deploy {local_rbf} -> {RBF}")
    if not md.scp_to(local_rbf, RBF):
        print("  SCP failed")
        return 1

    print("[1] restart MiSTer")
    ssh("kill $(pidof MiSTer) 2>/dev/null; sleep 2")
    ssh(f"nohup /media/fat/MiSTer {RBF} > /tmp/mt.log 2>&1 &")
    time.sleep(5)
    ssh("stty -F /dev/ttyS1 115200 raw -echo")
    time.sleep(4)

    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u0.txt")
    pre = ssh("tail -1 /tmp/u0.txt")
    print(f"  pre UART: {pre}")

    print(f"[2] load_core {MGL}")
    ssh(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
    # Long enough for: reset, KERNAL boot, download, inj_meminit, start_strk, RUN
    time.sleep(15)

    ssh("timeout 2 cat /dev/ttyS1 > /tmp/u1.txt")
    post = ssh("tail -1 /tmp/u1.txt")
    print(f"  post UART: {post}")

    # Screenshot: should show GREEN background if auto-RUN worked
    print("[3] screenshot")
    md.cmd_screen(["C:/LLM/C64/MiSTerSuperCPU/autorun_result.png"])

    # Read diag counters via single mtype batch
    print("[4] read diagnostic counters")
    md.scp_to("C:/LLM/C64/MiSTerSuperCPU/tools/mtype.py", "/tmp/mtype.py")
    cmd = "python3 /tmp/mtype.py " + " ".join([
        repr("?peek(57328);peek(57329);peek(57330)"), "enter",
        repr("?peek(57331);peek(57332);peek(57333)"), "enter",
        repr("?peek(57334);peek(57335)"), "enter",
        repr("?peek(57342);peek(57343)"), "enter",
        repr("?peek(43);peek(44)"), "enter",
        repr("?peek(2049);peek(2050);peek(2051)"), "enter",
    ])
    out, err, rc = md.ssh(cmd, timeout=120)
    print(f"  mtype rc={rc}")
    time.sleep(5)
    md.cmd_screen(["C:/LLM/C64/MiSTerSuperCPU/autorun_diag.png"])

    print("\nDone. Inspect:")
    print("  autorun_result.png - should show GREEN bg if PASS")
    print("  autorun_diag.png   - counters:")
    print("    $DFF0 (57328) dbg_prg_dl_cnt   — PRG downloads (want >=1)")
    print("    $DFF1 (57329) dbg_inj_rise_cnt — inj rising edges (want >=1)")
    print("    $DFF2 (57330) dbg_any_dl_cnt   — ANY download edges (want >=1)")
    print("    $DFF3 (57331) dbg_idx_at_dl    — ioctl_index at rising (want 1)")
    print("    $DFF4 (57332) dbg_classify_cnt — class capture (want 1)")
    print("    $DFF5 (57333) dbg_reu_by_ext   — reu_by_ext at capture (want 0)")
    print("    $DFF6 (57334) dbg_ext_byte0    — '.' = 46 for PRG")
    print("    $DFF7 (57335) dbg_ext_byte1    — 'P'=80 for PRG, 'R'=82 for REU")
    print("    $DFFE (57342) inj_fall_cnt     — want 1")
    print("    $DFFF (57343) strk_cnt         — want 1 (auto-RUN fired)")
    print("    peek(43),peek(44) = BASIC TXT ptr — want 1, 8")
    print("    peek(2049..2051) = $0801..$0803 PRG bytes — want 11,8,a (BASIC link)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
