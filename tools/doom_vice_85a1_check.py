#!/usr/bin/env python3
"""Does VICE Doom ever reach $2C:$85A1 (the error handler entry)?

VICE xscpu64 monitor rejects 24-bit breakpoint addresses, but accepts
16-bit `break exec $85A1`. When the BP fires, check PB register: if
$2C, same PC as hardware error path (divergence is downstream). If
different bank, VICE took a different code path (divergence upstream).

Output: tools/doom_vice_85a1_check/result.txt — break-fire count, PB
of each fire, and final state.
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_85a1_check"
PORT     = 6510
PROMPT   = b"(C:$"


def drain(s, idle_s=0.4, max_s=8.0):
    s.settimeout(idle_s)
    buf = b""
    end = time.time() + max_s
    while time.time() < end:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            break
        if not ch: break
        buf += ch
    return buf


def expect_prompt(s, timeout=20.0):
    s.settimeout(timeout)
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch: break
        buf += ch
        if PROMPT in buf:
            return buf
    return buf


def cmd(s, line, timeout=20.0):
    s.sendall((line.rstrip() + "\r\n").encode())
    return expect_prompt(s, timeout=timeout).decode(errors="replace")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    args = [
        VICE_EXE,
        "-reu", "-reusize", "16384", "+reuimagerw",
        "-reuimage", DOOM_REU,
        "-autostartprgmode", "1",
        "-autostart", DOOM_LDR,
        "-remotemonitor",
        "-remotemonitoraddress", "127.0.0.1:{}".format(PORT),
        "-warp",
        "+sound",
    ]
    print("Launching VICE")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Wait 30s WITHOUT connecting. The remote-monitor TCP connect causes VICE
    # to pause, which interrupts autostart. Let autostart fire & Doom boot first.
    print("waiting 30s for VICE autostart + Doom boot (warp) ...")
    time.sleep(30)

    s = None
    for _ in range(10):
        try:
            s = socket.socket()
            s.settimeout(2)
            s.connect(("127.0.0.1", PORT))
            break
        except (socket.timeout, ConnectionRefusedError):
            s = None
            time.sleep(1)
    if not s:
        print("ERROR: monitor never came up")
        p.terminate()
        return 1
    print("monitor connected")
    drain(s, idle_s=0.5, max_s=3.0)

    # Confirm Doom actually booted — check current PB
    out_r = cmd(s, "r", timeout=5)
    print("  state at connect:", out_r[:240])

    print("setting break exec $85A1 ...")
    out = cmd(s, "break exec $85a1", timeout=10)
    print("  >>>", out[-300:])

    # Resume; collect break events for 60s
    print("resuming Doom for 60s warp; collecting $85A1 hits ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    fires = []  # list of (PB, PC, A) at each fire
    end_t = time.time() + 60.0
    buf = b""
    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch:
            break
        buf += ch
        if PROMPT in buf:
            text = buf.decode(errors='replace')
            # Look for register dump (auto-emitted on break)
            m = re.search(r"\.;([0-9a-f]{2})\s+([0-9a-f]{4})\s+([0-9a-f]{4})", text)
            if m:
                pb = m.group(1); pc = m.group(2); a = m.group(3)
                fires.append((pb, pc, a))
                if len(fires) <= 10 or len(fires) % 10 == 0:
                    print(f"  fire #{len(fires)}: PB={pb} PC={pc} A={a}")
            else:
                # Maybe trace fires without register dump. Get registers explicitly.
                s.sendall(b"r\r\n")
                time.sleep(0.1)
                buf = b""
                continue
            # Resume
            s.sendall(b"x\r\n")
            buf = b""

    print(f"\ntotal $85A1 hits in 90s: {len(fires)}")

    # Summarize PB distribution
    from collections import Counter
    pb_ctr = Counter(pb for pb, pc, a in fires)
    print(f"PB distribution: {dict(pb_ctr)}")

    # Force into monitor
    s.sendall(b"\r\n")
    time.sleep(1)
    drain(s, idle_s=0.5, max_s=3.0)
    out_r = cmd(s, "r", timeout=5)
    print("final regs:", out_r[:200])

    result = os.path.join(OUT_DIR, "result.txt")
    with open(result, 'w', errors='replace') as f:
        f.write("VICE Doom $85A1 break check (90s warp)\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"Total $85A1 fires: {len(fires)}\n")
        f.write(f"PB distribution: {dict(pb_ctr)}\n\n")
        f.write("First 30 fires (PB, PC, A):\n")
        for pb, pc, a in fires[:30]:
            f.write(f"  PB={pb} PC={pc} A={a}\n")
        f.write("\nFinal registers:\n" + out_r + "\n")

        # Interpretation
        f.write("\nInterpretation:\n")
        if not fires:
            f.write("  ZERO hits: VICE never reaches $85A1.\n")
            f.write("  → divergence is UPSTREAM of $85A1 — VICE skips the error\n")
            f.write("    path entirely. The bound check that drives execution\n")
            f.write("    to $85A1 succeeds in VICE (or executes a different path).\n")
        elif "2c" in pb_ctr:
            f.write(f"  {pb_ctr['2c']} hits with PB=$2C: VICE reaches the same\n")
            f.write("    PC as hardware. → divergence is AT or DOWNSTREAM of $85A1\n")
            f.write("    (e.g., the M-ring sub-calls do something different).\n")
        else:
            f.write(f"  Hits but not in PB=$2C: {dict(pb_ctr)}\n")
            f.write("  → $85A1 is a coincidental address in another code bank;\n")
            f.write("    not the same code as hardware's halt path.\n")
    print("wrote", result)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
