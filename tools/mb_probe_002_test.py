#!/usr/bin/env python3
"""
mb_probe_002_test.py — Milestone B v2 (Codex Design 3) wedge discriminator.

Build mb-probe-002 has the v2 vblank-snapped bridge probes on top of:
  - SAME_CLOCK_PASSTHROUGH = '0'  (MCP path active)
  - Option (a) PRECHARGE FSM (silicon-validated)
  - v13d CIA1 + cia2_write_safe gates
  - Option F/G UART probes
  - milestone-b v1 probes: FS / DI / RQ / AK / VF
  - milestone-b v2 probes: WD / FL / GM (NEW — vblank-snapped)

What v2 fixes vs v1:
  - RQ/AK now WRAP and are vblank-SNAPSHOTTED (v1 saturated at $FFFF
    before first vblank, making Race β untestable).
  - VF is also vblank-snapshotted (was live multi-bit, prone to CDC
    tearing).
  - WD (wait_dwell_max): max clk_cpu cycles in WAIT_ACK per frame.
    *The real Race β detector.* The bridge is one-outstanding by
    structure, so RQ-AK gap can't widen; what matters is "how long
    did the bridge sit in WAIT_ACK". A WAIT_ACK wedge = WD growing
    toward $FFFF.
  - FL (activity flags): sticky-per-frame:
      bit 0 = req_seen   (any IDLE->PENDING this frame)
      bit 1 = ack_seen   (any WAIT_ACK->LATCH this frame)
      bit 2 = wait_seen  (any clk_cpu in WAIT_ACK this frame)
      bit 7 = wd_sat     (wait_dwell_max saturated to $FFFF)
  - GM (gap_max): max RQ-AK gap per frame. Sanity check — should
    always be 0 or 1; >1 means one-outstanding invariant broken.

Rubric (replaces v1's untestable Race β check):
  - Race β confirmed if WD saturates (or stays high) AND FL bit 2
    (wait_seen) = 1 throughout wedge.
  - "Bridge stalled in WAIT_ACK" definitive if WD >> typical healthy
    dwell. Healthy: WD ≤ ~10 clk_cpu (single arbiter slot turnaround).
    Wedge: WD growing to $FFFF.
  - "Bridge alive but source IRQ stopped" if WD low + FL=07 (all
    activity bits set) + IF/C1/DR frozen.
  - "Bridge dead" if FL=00 (no req/ack/wait events for a whole frame).
  - Race α (PC byte-aliasing) check carries over from v1.
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
                       "mb_probe_002")
os.makedirs(OUT_DIR, exist_ok=True)


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS,
                timeout=10, look_for_keys=False, allow_agent=False)
    return ssh


def run_cmd(ssh, cmd, timeout=30):
    _, stdout, stderr = ssh.exec_command(cmd, timeout=timeout)
    return stdout.read().decode("utf-8", errors="replace"), \
           stderr.read().decode("utf-8", errors="replace")


def screenshot(ssh, name):
    path = os.path.join(OUT_DIR, name)
    run_cmd(ssh, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2)
    out, _ = run_cmd(ssh,
        "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    latest = out.strip().splitlines()[0] if out.strip() else None
    if not latest:
        print(f"  ! no screenshot for {name}")
        return None
    sftp = ssh.open_sftp()
    sftp.get(latest, path)
    sftp.close()
    print(f"  shot -> {name}")
    return path


def mtype(ssh, *args, settle=0.5):
    quoted = " ".join(f"'{a}'" for a in args)
    run_cmd(ssh, f"python3 /tmp/mtype.py {quoted}")
    time.sleep(settle)


def mgl_load_disk(ssh, d64_path="/media/fat/games/C64/lorenz_disk1.d64"):
    mgl = (f'<mistergamedescription>\n'
           f'<rbf>_Test/C64</rbf>\n'
           f'<file delay="2" type="s" index="0" path="{d64_path}"/>\n'
           f'</mistergamedescription>\n')
    sftp = ssh.open_sftp()
    with sftp.open("/tmp/mb_probe_002.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    run_cmd(ssh, "echo load_core /tmp/mb_probe_002.mgl > /dev/MiSTer_cmd")


def parse_uart_fields(path):
    """Pull FS DI RQ AK VF WD FL GM + PC values from UART lines."""
    samples = []
    pat = re.compile(
        r"PC:([0-9A-Fa-f]+).*?"
        r"FS:([0-9A-Fa-f]+)\s+"
        r"DI:([0-9A-Fa-f]+)\s+"
        r"RQ:([0-9A-Fa-f]+)\s+"
        r"AK:([0-9A-Fa-f]+)\s+"
        r"VF:([0-9A-Fa-f]+)\s+"
        r"WD:([0-9A-Fa-f]+)\s+"
        r"FL:([0-9A-Fa-f]+)\s+"
        r"GM:([0-9A-Fa-f]+)"
    )
    with open(path) as f:
        for line in f:
            m = pat.search(line)
            if m:
                samples.append({
                    "pc": int(m.group(1), 16),
                    "fs": int(m.group(2), 16),
                    "di": int(m.group(3), 16),
                    "rq": int(m.group(4), 16),
                    "ak": int(m.group(5), 16),
                    "vf": int(m.group(6), 16),
                    "wd": int(m.group(7), 16),
                    "fl": int(m.group(8), 16),
                    "gm": int(m.group(9), 16),
                })
    return samples


def analyze(samples, label):
    """Summarize probe outputs against v2 wedge-classification rubric."""
    if not samples:
        print(f"  {label}: NO MATCHING UART LINES")
        return
    print(f"  {label}: {len(samples)} samples")
    pcs = [s["pc"] for s in samples]
    fss = [s["fs"] for s in samples]
    dis = [s["di"] for s in samples]
    rqs = [s["rq"] for s in samples]
    aks = [s["ak"] for s in samples]
    vfs = [s["vf"] for s in samples]
    wds = [s["wd"] for s in samples]
    fls = [s["fl"] for s in samples]
    gms = [s["gm"] for s in samples]

    print(f"    PC unique: {len(set(pcs))}  first=${pcs[0]:04X}  last=${pcs[-1]:04X}")
    print(f"    PC top-5: {sorted(set(pcs), key=lambda x: -pcs.count(x))[:5]}")
    print(f"    FS dist: {dict((s, fss.count(s)) for s in sorted(set(fss)))}")
    print(f"    DI uniq: {len(set(dis))}  values: {sorted(set(dis))[:10]}")
    # WRAPPING counter: compute deltas with wraparound for v2.
    def wrap_delta(seq, width):
        mod = 1 << width
        return [(b - a) % mod for a, b in zip(seq, seq[1:])]
    print(f"    RQ-snap: first=${rqs[0]:04X} last=${rqs[-1]:04X} "
          f"reqs-since-first={(rqs[-1] - rqs[0]) % 0x10000}")
    print(f"    AK-snap: first=${aks[0]:04X} last=${aks[-1]:04X} "
          f"acks-since-first={(aks[-1] - aks[0]) % 0x10000}")
    print(f"    VF-snap: first=${vfs[0]:02X} last=${vfs[-1]:02X}")
    # v2 specific: WD/FL/GM
    print(f"    WD: min={min(wds)} max={max(wds)} last={wds[-1]}  "
          f"unique-vals={len(set(wds))}")
    if max(wds) >= 0xFFF0:
        print(f"    !! WD APPROACHING SATURATION ($FFFF). "
              f"Bridge stalled in WAIT_ACK confirmed.")
    elif max(wds) >= 100:
        print(f"    !! WD high (>{max(wds)}). Bridge spending notable time "
              f"in WAIT_ACK; investigate.")
    print(f"    FL dist: {dict((s, fls.count(s)) for s in sorted(set(fls)))}")
    # Decode FL bits
    flag_names = ["req_seen", "ack_seen", "wait_seen", "?", "?", "?", "?", "wd_sat"]
    fl_dec = {}
    for fl in fls:
        for b in range(8):
            if fl & (1 << b):
                fl_dec[flag_names[b]] = fl_dec.get(flag_names[b], 0) + 1
    print(f"    FL bits set in N samples: {fl_dec}")
    if any(fl == 0 for fl in fls):
        n_dead = sum(1 for fl in fls if fl == 0)
        print(f"    !! {n_dead}/{len(fls)} samples have FL=0 -> bridge made "
              f"NO progress that frame. Source FSM stalled.")
    if all((fl & 0x04) for fl in fls):
        print(f"    !! wait_seen set in ALL frames -> bridge always "
              f"touching WAIT_ACK each frame.")
    print(f"    GM: min={min(gms)} max={max(gms)} last={gms[-1]}")
    if max(gms) > 1:
        print(f"    !! GM>1 ({max(gms)}) -> one-outstanding FSM invariant "
              f"broken. Bug.")
    # Race α (carry-over from v1)
    aliased = [pc for pc in pcs if (pc >> 8) == (pc & 0xff)]
    print(f"    PC byte-aliased (hi==lo): {len(aliased)}/{len(pcs)}")

    # Combined classification
    print(f"  -- Classification --")
    avg_wd = sum(wds) / len(wds)
    fl_zero = sum(1 for fl in fls if fl == 0)
    if max(wds) >= 0xFFF0:
        print("    --> WEDGE MODE: bridge stalled in WAIT_ACK (Race β CONFIRMED)")
    elif fl_zero > len(fls) // 2:
        print("    --> WEDGE MODE: bridge dead (no FSM progress in most frames)")
    elif aliased:
        print("    --> RACE α CONFIRMED: PC byte-aliasing detected")
    elif avg_wd < 10 and (rqs[-1] - rqs[0]) % 0x10000 > 100:
        print("    --> Bridge healthy but external (CIA/IEC) wedge — bridge "
              "is delivering bytes normally; check IRQ/IEC state")
    else:
        print(f"    --> Classification inconclusive; WD avg={avg_wd:.1f}, "
              f"req-delta={(rqs[-1]-rqs[0]) % 0x10000}, "
              f"PC pattern needs manual inspection")


def main():
    print("== mb_probe_002 ==")
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
    time.sleep(5)
    screenshot(ssh, "03_mid_t5.png")
    time.sleep(10)
    screenshot(ssh, "04_mid_t15.png")
    time.sleep(10)
    screenshot(ssh, "05_mid_t25.png")

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
