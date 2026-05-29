#!/usr/bin/env python3
"""d0bx_full_hw_sweep.py — confirm the FULL SCPU status read-mux on silicon.

Iteration-5 HW-verified only $D0B0 and $D0B2. This sweeps every converted
clause via BASIC PEEK (emulation-mode 65C816 -> exercises the cpuAddr_816
read-mux), cross-checking against VICE xscpu64 ground truth (semantic bits,
masking the optim&7 low-3 bits VICE ORs in):

  $D0B0 53424 -> 64  ($40 v2/64 mode-detect)            VICE $41 (=$40|optim)
  $D0B2 53426 -> 128 ($80 hwenable, sys1mhz=0)          VICE $81
  $D0B6 53430 -> 128 ($80 emulation mode)               VICE $81
  $D0BC 53436 -> 0   ($00 dosext=0 => SuperCPU present) VICE $01
  $D0B5 53429 -> 0   (we drive b6=speed only)           VICE $81 (jiffy b7)
  $D0B8 53432 -> 0/64 (turbo/1MHz speed flag)           VICE $01
  $D0B4 53428 -> optim low bits                         VICE $C1
  $D0B3 53427 -> 0                                       VICE $C1
  $D078 53368 -> 0   (MiSTer cache-flush repurpose)     VICE $FF
  $D07E 53374 -> rom_vis based                          VICE $FF

The detection-critical assertions are $D0B0 b7-6==01, $D0B2 b7 (after enable),
$D0B6 b7, $D0BC b7==0. Run only when MiSTer ownership is free.
"""
import os, sys, time, socket
import paramiko

IP, USER, PW = "192.168.50.130", "root", "1"
RBF_LOCAL = r"C:\LLM\C64\MiSTerSuperCPU\C64.rbf"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "d0bx_full_hw_sweep")
os.makedirs(OUT, exist_ok=True)


def conn():
    s = socket.create_connection((IP, 22), timeout=10)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(IP, username=USER, password=PW, sock=s,
              look_for_keys=False, allow_agent=False, timeout=10)
    return c


def run(c, cmd, t=30):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode("utf-8", "replace"), e.read().decode("utf-8", "replace")


def shot(c, name):
    run(c, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    o, _ = run(c, "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    latest = o.strip().splitlines()[0] if o.strip() else None
    if not latest:
        print(f"  ! no screenshot for {name}")
        return
    sf = c.open_sftp(); sf.get(latest, os.path.join(OUT, name)); sf.close()
    print(f"  shot -> {name}")


def mtype(c, *args, settle=0.7):
    q = " ".join(f"'{a}'" for a in args)
    run(c, f"python3 /tmp/mtype.py {q}")
    time.sleep(settle)


def main():
    c = conn()
    core, _ = run(c, "cat /tmp/CORENAME 2>/dev/null")
    print(f"CORENAME={core.strip()!r}")
    if core.strip() and core.strip() not in ("C64", "MENU"):
        print("MiSTer owned by another core — aborting.")
        return
    run(c, "echo 'agent=c64 task=d0bx_full_sweep' > /tmp/mister_session.lock")
    run(c, "echo C64 > /tmp/CORENAME")

    print("Uploading mtype.py + deploying read-mux RBF (97392a1f)...")
    sf = c.open_sftp()
    sf.put(r"C:\LLM\C64\MiSTerSuperCPU\tools\mtype.py", "/tmp/mtype.py")
    sf.put(RBF_LOCAL, "/media/fat/_Test/C64.rbf")
    sf.close()
    run(c, "echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd")
    time.sleep(13)
    shot(c, "00_boot.png")

    # Enable register window, then PEEK all 10 regs across two PRINT lines.
    print("Enable $D07E + PEEK full status set...")
    mtype(c, "POKE", "space", "53374,0", "enter", settle=0.8)
    # Row of detect/status regs
    mtype(c, "PRINTPEEK(53424)PEEK(53426)PEEK(53430)PEEK(53436)", "enter", settle=1.2)
    #            $D0B0       $D0B2       $D0B6       $D0BC
    mtype(c, "PRINTPEEK(53429)PEEK(53432)PEEK(53428)PEEK(53427)", "enter", settle=1.2)
    #            $D0B5       $D0B8       $D0B4       $D0B3
    mtype(c, "PRINTPEEK(53368)PEEK(53374)", "enter", settle=1.2)
    #            $D078       $D07E
    shot(c, "01_full_sweep.png")

    print(f"\nInspect {OUT}\\01_full_sweep.png. Expected (detection-critical):")
    print("  line1: 64 128 128 0   ($D0B0 $D0B2 $D0B6 $D0BC)")
    print("  -> $D0B0=64 (v2/64), $D0B2=128 (hwenable), $D0B6=128 (emu), $D0BC=0 (present)")
    print("  line2: $D0B5 $D0B8 $D0B4 $D0B3  (status, no known consumer)")
    print("  line3: $D078 $D07E")
    # Release after test
    run(c, "rm -f /tmp/mister_session.lock")
    print("Released lock (CORENAME left = C64; load Menu manually to fully free).")
    c.close()


if __name__ == "__main__":
    main()
