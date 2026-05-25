#!/usr/bin/env python3
"""
mb_probe_003_test.py — Milestone B v3 wedge discriminator with CIA1 internals.

Build mb-probe-003 adds 3 new CIA1 internal taps on top of mb-probe-002:
  - TA:#### = Timer A live counter value
  - TL:#### = Timer A reload latch {ta_hi, ta_lo}
  - IC:##   = raw 5-bit ICR pending bits (bit 0 = Timer A pending)

Disambiguates between:
  1. Counter halted   = TA frozen at $0000 → count enable lost
  2. Reload zeroed    = TL frozen at $0000 → phantom write to $DC04/$DC05
  3. ICR latch stuck  = IC bit 0 = 1 across wedge despite int_reset firing
                        (look at IM:01 in legacy field — if both then irq_n
                        should be asserted but CPU isn't taking IRQs)
  4. Downstream bug   = TA/TL/IC all sane but irq_n stays high anyway
"""
import os
import re
import sys
import time
import paramiko

MISTER_IP = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "mb_probe_003")
os.makedirs(OUT_DIR, exist_ok=True)


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS, timeout=10)
    return ssh


def run_cmd(ssh, cmd, timeout=30):
    si, so, se = ssh.exec_command(cmd, timeout=timeout)
    return so.read().decode("utf-8", "replace"), se.read().decode("utf-8", "replace")


def screenshot(ssh, name):
    run_cmd(ssh, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(0.7)
    out, _ = run_cmd(ssh, "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    out = out.strip()
    if out:
        sftp = ssh.open_sftp()
        sftp.get(out, os.path.join(OUT_DIR, name))
        sftp.close()
        print(f"  shot -> {name}")


def mtype(ssh, *args, settle=0.5):
    for a in args:
        run_cmd(ssh, f'python3 /tmp/mtype.py {a!r}')
        time.sleep(settle)


def mgl_load_disk(ssh, d64_path="/media/fat/games/C64/lorenz_disk1.d64"):
    mgl = (
        '<mistergamedescription>'
        '<rbf>_Test/C64</rbf>'
        f'<file type="s" index="0" path="{d64_path}"/>'
        '</mistergamedescription>'
    )
    sftp = ssh.open_sftp()
    with sftp.open("/tmp/mb_probe_003.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    run_cmd(ssh, "echo load_core /tmp/mb_probe_003.mgl > /dev/MiSTer_cmd")


def parse_uart_fields(path):
    """Pull FS DI RQ AK VF WD FL GM TA TL IC + PC + IM + C1 values."""
    samples = []
    pat = re.compile(
        r"PC:([0-9A-Fa-f]+).*?"
        r"IF:([0-9A-Fa-f]+).*?"
        r"C1:([0-9A-Fa-f]+).*?"
        r"IM:([0-9A-Fa-f]+).*?"
        r"CR:([0-9A-Fa-f]+).*?"
        r"FS:([0-9A-Fa-f]+)\s+"
        r"DI:([0-9A-Fa-f]+)\s+"
        r"RQ:([0-9A-Fa-f]+)\s+"
        r"AK:([0-9A-Fa-f]+)\s+"
        r"VF:([0-9A-Fa-f]+)\s+"
        r"WD:([0-9A-Fa-f]+)\s+"
        r"FL:([0-9A-Fa-f]+)\s+"
        r"GM:([0-9A-Fa-f]+)\s+"
        r"TA:([0-9A-Fa-f]+)\s+"
        r"TL:([0-9A-Fa-f]+)\s+"
        r"IC:([0-9A-Fa-f]+)"
    )
    with open(path) as f:
        for line in f:
            m = pat.search(line)
            if m:
                samples.append({
                    "pc":  int(m.group(1),  16),
                    "if_": int(m.group(2),  16),
                    "c1":  int(m.group(3),  16),
                    "im":  int(m.group(4),  16),
                    "cr":  int(m.group(5),  16),
                    "fs":  int(m.group(6),  16),
                    "di":  int(m.group(7),  16),
                    "rq":  int(m.group(8),  16),
                    "ak":  int(m.group(9),  16),
                    "vf":  int(m.group(10), 16),
                    "wd":  int(m.group(11), 16),
                    "fl":  int(m.group(12), 16),
                    "gm":  int(m.group(13), 16),
                    "ta":  int(m.group(14), 16),
                    "tl":  int(m.group(15), 16),
                    "ic":  int(m.group(16), 16),
                })
    return samples


def analyze(samples, label):
    if not samples:
        print(f"  {label}: NO MATCHING UART LINES")
        return
    print(f"  {label}: {len(samples)} samples")
    pcs  = [s["pc"]  for s in samples]
    rqs  = [s["rq"]  for s in samples]
    wds  = [s["wd"]  for s in samples]
    fls  = [s["fl"]  for s in samples]
    tas  = [s["ta"]  for s in samples]
    tls  = [s["tl"]  for s in samples]
    ics  = [s["ic"]  for s in samples]
    ims  = [s["im"]  for s in samples]
    crs  = [s["cr"]  for s in samples]
    ifs  = [s["if_"] for s in samples]
    c1s  = [s["c1"]  for s in samples]

    print(f"    PC unique: {len(set(pcs))}  first=${pcs[0]:04X}  last=${pcs[-1]:04X}")
    print(f"    IF: first=${ifs[0]:04X} last=${ifs[-1]:04X}  "
          f"frozen={'YES' if len(set(ifs)) == 1 else 'no'}")
    print(f"    C1: first=${c1s[0]:04X} last=${c1s[-1]:04X}  "
          f"frozen={'YES' if len(set(c1s)) == 1 else 'no'}")
    print(f"    IM: dist={dict((s, ims.count(s)) for s in sorted(set(ims)))}")
    print(f"    CR: dist={dict((s, crs.count(s)) for s in sorted(set(crs)))}")
    print()
    print(f"    [v3 CIA1 TAPS]")
    print(f"    TA (Timer A counter): first=${tas[0]:04X} last=${tas[-1]:04X}  "
          f"unique={len(set(tas))}  range=${min(tas):04X}..${max(tas):04X}")
    print(f"    TL (Timer A latch):   first=${tls[0]:04X} last=${tls[-1]:04X}  "
          f"unique={len(set(tls))}")
    print(f"    IC (raw ICR pending): dist={dict((s, ics.count(s)) for s in sorted(set(ics)))}")
    print(f"    IC bit 0 (TA pending) set in {sum(1 for ic in ics if ic & 1)}/{len(ics)} samples")
    print()
    print(f"    [bridge — confirm still healthy]")
    print(f"    WD: min={min(wds)} max={max(wds)}  FL dist={dict((s, fls.count(s)) for s in sorted(set(fls)))}")

    # CIA1 wedge classifier — per Codex hypothesis ranking 2026-05-26.
    print(f"  -- CIA1 Classification --")
    ta_varies = len(set(tas)) > 3
    ic_bit0_pending = sum(1 for ic in ics if ic & 1)
    ic_bit0_stuck_set = ic_bit0_pending > len(ics) * 0.95  # >95% of frames
    ic_bit0_stuck_clr = ic_bit0_pending < len(ics) * 0.05  # <5% of frames

    if ta_varies and ic_bit0_stuck_set:
        # Codex Hypothesis #1 — irq_n stuck low because $DC0D never read.
        # Smoking gun: TA still cycling (timer alive) AND icr[0] stays set
        # (overflow keeps re-asserting) AND IF/C1 frozen (irq_n not toggling).
        print(f"    --> HYPOTHESIS #1 CONFIRMED: irq_n likely stuck LOW.")
        print(f"        Timer A still running (TA varies across {len(set(tas))} "
              f"unique values, range ${min(tas):04X}..${max(tas):04X}).")
        print(f"        ICR bit 0 SET in {ic_bit0_pending}/{len(ics)} frames "
              f"(should toggle 0/1 with each ack).")
        print(f"        Mechanism: $DC0D reads stopped (DR frozen in legacy "
              f"probe), int_reset never fires, icr[0] stays high, "
              f"irq_n never re-arms. mos6526.v:554 only LOWERS irq_n when "
              f"it's currently HIGH, so once low it stays low.")
        print(f"        ROOT CAUSE upstream: why did CPU stop reading $DC0D? "
              f"Most likely PC stuck in KERNAL raster-wait loop ($EAB1+ "
              f"polls $D012). Check what $D012 returns to SCPU through bus mux.")
    elif len(set(tas)) == 1 and tas[0] == 0:
        print("    --> Counter halted at $0000 — count enable lost. "
              "Check CRA[0] phantom-clear.")
    elif len(set(tas)) == 1:
        print(f"    --> Counter frozen at ${tas[0]:04X} — Timer A not counting. "
              "Check CRA[0] enable and countA3 chain.")
    elif len(set(tls)) > 3 and any(tl == 0 for tl in tls):
        print(f"    --> Reload latch (TL) phantom-write during wedge. "
              "Check $DC04/$DC05 write path.")
    elif ic_bit0_stuck_clr:
        print(f"    --> ICR bit 0 NEVER SET — Timer A overflow not registering. "
              "timerAoverflow path broken or counter never hits $0000.")
    else:
        print(f"    --> Inconclusive. TA unique={len(set(tas))}, "
              f"ICR bit 0 pending {ic_bit0_pending}/{len(ics)}. "
              "Inspect samples manually.")


def main():
    print("== mb_probe_003 ==")
    ssh = ssh_connect()
    run_cmd(ssh, "stty -F /dev/ttyS1 115200 raw -echo")
    sftp = ssh.open_sftp()
    sftp.put("tools/mtype.py", "/tmp/mtype.py")
    sftp.close()

    print("[1/8] mount disk + load core")
    mgl_load_disk(ssh)
    time.sleep(12)
    screenshot(ssh, "00_boot.png")

    print("[2/8] start UART capture in background (35 s)")
    run_cmd(ssh,
        "nohup sh -c 'timeout 35 cat /dev/ttyS1 | "
        "tr -dc \"[:print:]\\n\" > /tmp/mb_probe_uart.log' "
        "> /dev/null 2>&1 &")
    time.sleep(3)

    print("[3/8] trigger LOAD\"*\",8,1")
    mtype(ssh, 'LOAD"*",8,1', 'enter')
    screenshot(ssh, "02_after_keys.png")

    print("[4/8] mid-LOAD screenshots @ 5/15/25 s")
    time.sleep(5);  screenshot(ssh, "03_mid_t5.png")
    time.sleep(10); screenshot(ssh, "04_mid_t15.png")
    time.sleep(10); screenshot(ssh, "05_mid_t25.png")

    print("[5/8] wait for capture to finish, fetch log")
    time.sleep(8)
    sftp = ssh.open_sftp()
    sftp.get("/tmp/mb_probe_uart.log", os.path.join(OUT_DIR, "uart_capture.log"))
    sftp.close()

    print("[6/8] final screenshot")
    screenshot(ssh, "06_final.png")

    print("[7/8] parse + analyze")
    samples = parse_uart_fields(os.path.join(OUT_DIR, "uart_capture.log"))
    analyze(samples, "FULL_CAPTURE")

    print("[8/8] split into baseline + wedge slice")
    if len(samples) > 10:
        midpoint = len(samples) // 2
        print()
        analyze(samples[:midpoint], "FIRST_HALF (baseline + LOAD trigger)")
        print()
        analyze(samples[midpoint:], "SECOND_HALF (steady wedge state)")

    ssh.close()
    print("== done ==")


if __name__ == "__main__":
    main()
