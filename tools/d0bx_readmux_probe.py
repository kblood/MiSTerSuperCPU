#!/usr/bin/env python3
"""
d0bx_readmux_probe.py — verify the 2026-05-29 SCPU status-register read-mux fix.

Background: the $D0Bx / $D07E SCPU status registers were read-decoded with the
DEAD `cs_vic + cpuAddr(11:0)` mechanism (every read returned $FF / VIC-mirror
garbage on the 65C816 path). The fix converts them to the hardware-proven
16-bit `cpuAddr_816` compare (same mechanism the $D27x / $FFEx clauses use).

Detect sequence (standard CMD SuperCPU): write $D07E to enable the register
window (sets scpu_regs_enabled=1, scpu_hwenable=1), THEN read the status regs.

Expected AFTER fix:
  PEEK(53424) $D0B0 = 64   ($40  SuperCPU v2, C64 mode — presence detect)
  PEEK(53426) $D0B2 = 128  ($80  hwenable=1, sys_1mhz=0)
Expected BEFORE fix (current shipped RBF):
  both = 255 ($FF open-bus / VIC mirror)

POKE 53374,128 keeps bit7=1 so scpu_rom_vis stays set (no bootmap side-effect).

Run only when MiSTer ownership is free (CORENAME=C64 or empty). Deploys the
freshly built RBF to /media/fat/_Test/C64.rbf first.
"""
import os, sys, time, socket
import paramiko

IP, USER, PW = "192.168.50.130", "root", "1"
RBF_LOCAL = r"C:\LLM\C64\MiSTerSuperCPU\C64.rbf"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "d0bx_readmux_probe")
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


def mtype(c, *args, settle=0.6):
    q = " ".join(f"'{a}'" for a in args)
    run(c, f"python3 /tmp/mtype.py {q}")
    time.sleep(settle)


def main():
    c = conn()
    core, _ = run(c, "cat /tmp/CORENAME 2>/dev/null")
    print(f"CORENAME={core.strip()!r}")
    if core.strip() and core.strip() not in ("C64", "MENU"):
        print("MiSTer owned by another core — aborting (cooperation protocol).")
        return

    print("Uploading mtype.py + deploying RBF...")
    sf = c.open_sftp()
    sf.put(r"C:\LLM\C64\MiSTerSuperCPU\tools\mtype.py", "/tmp/mtype.py")
    sf.put(RBF_LOCAL, "/media/fat/_Test/C64.rbf")
    sf.close()
    run(c, "echo C64 > /tmp/CORENAME")
    run(c, "echo load_core /media/fat/_Test/C64.rbf > /dev/MiSTer_cmd")
    time.sleep(12)
    shot(c, "00_boot.png")

    # Enable the SCPU register window, then read $D0B0 / $D0B2 / $D0BC.
    print("POKE $D07E (enable regs) + PEEK $D0B0/$D0B2/$D0BC ...")
    mtype(c, "POKE", "space", "53374,128", "enter", settle=0.8)
    mtype(c, "PRINTPEEK(53424)", "enter", settle=1.0)   # $D0B0 -> expect 64
    mtype(c, "PRINTPEEK(53426)", "enter", settle=1.0)   # $D0B2 -> expect 128
    mtype(c, "PRINTPEEK(53436)", "enter", settle=1.0)   # $D0BC
    shot(c, "01_peeks.png")

    print(f"\nInspect {OUT}\\01_peeks.png:")
    print("  $D0B0 (53424): 64  = PASS (fix live), 255 = still dead")
    print("  $D0B2 (53426): 128 = PASS (hwenable set)")
    c.close()


if __name__ == "__main__":
    main()
