#!/usr/bin/env python3
"""Capture VICE CPU history (`chis`) over Doom's steady-state loop.

VICE remote monitor's `chis N` dumps the last N executed instructions
including PB:PC, opcode disassembly, and register state. This is the
oracle data we need for the bank $2A loop.

We let VICE warp through Doom autostart + reach steady state, then
issue `chis 2000` to pull a representative trace. Save raw to file.

Output: tools/doom_vice_chis/trace.txt
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_chis"
PORT     = 6510
PROMPT   = b"(C:$"


def expect_prompt(s, timeout=30.0):
    s.settimeout(min(timeout, 2.0))
    buf = b""
    end = time.time() + timeout
    last_data_t = time.time()
    while time.time() < end:
        try:
            ch = s.recv(65536)
            last_data_t = time.time()
        except socket.timeout:
            # If we've seen prompt and idle for >0.5s, return
            if PROMPT in buf and (time.time() - last_data_t) > 0.5:
                return buf
            continue
        if not ch: break
        buf += ch
    return buf


def cmd(s, line, timeout=30.0):
    s.sendall((line.rstrip() + "\r\n").encode())
    return expect_prompt(s, timeout=timeout).decode(errors="replace")


def drain(s, idle_s=0.4, max_s=3.0):
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
    print("waiting 30s for warp boot ...")
    time.sleep(30)

    s = None
    for _ in range(10):
        try:
            s = socket.socket(); s.settimeout(3); s.connect(("127.0.0.1", PORT))
            break
        except (socket.timeout, ConnectionRefusedError):
            s = None; time.sleep(1)
    if not s:
        print("ERROR: monitor never came up"); p.terminate(); return 1
    print("monitor connected")
    drain(s)

    # First, enable history recording. xscpu64 default may be off or small.
    print("enabling CPU history with size 65536 ...")
    out = cmd(s, "chistory 65536", timeout=10)
    print("  >>>", out[-200:].strip())

    # Resume and run steady state for 10s real-time
    print("resuming for 10s of warp execution ...")
    s.sendall(b"x\r\n")
    time.sleep(10)

    # Force back into monitor
    s.sendall(b"\r\n")
    time.sleep(0.5)
    drain(s, idle_s=0.5, max_s=2.0)

    # Confirm state
    out_r = cmd(s, "r", timeout=5)
    print("  state:", out_r[:200])

    # Dump CPU history (last N instructions). Try different sizes.
    print("dumping chis 2000 ...")
    chis_out = cmd(s, "chis 2000", timeout=60)
    print(f"  chis returned {len(chis_out)} chars")

    trace_path = os.path.join(OUT_DIR, "trace.txt")
    with open(trace_path, 'w', errors='replace') as f:
        f.write(chis_out)
    print("wrote", trace_path)

    # Parse: extract PB:PC distribution and unique instruction count
    lines = chis_out.split("\n")
    print(f"  lines: {len(lines)}")

    # Lines from chis look like: ".XX:YYYY  HEX  MNEMONIC  flags"
    # Extract PB:PC pairs
    from collections import Counter
    pcs = []
    for L in lines:
        m = re.search(r"\.([0-9a-fA-F]{2}):([0-9a-fA-F]{4})", L)
        if m:
            pcs.append((m.group(1).lower(), m.group(2).lower()))
    print(f"  parsed {len(pcs)} instruction lines")

    pb_ctr = Counter(pb for pb, _ in pcs)
    print("  PB distribution in trace:")
    for pb, n in sorted(pb_ctr.items(), key=lambda x: -x[1])[:10]:
        print(f"    PB=${pb}: {n}")

    # Disassemble bank $2A loop region directly
    print("\ndisassembling $2A:$5596-$5640 ...")
    out_d1 = cmd(s, "disass $2a5596 $2a5640", timeout=10)
    print(out_d1[:2000])

    # Also try shorter syntax in case 24-bit format fails
    if "Address too large" in out_d1 or "Unexpected" in out_d1:
        print("(24-bit syntax rejected; trying alternative forms)")
        out_d2 = cmd(s, "disass $5596 $5640", timeout=10)
        print(out_d2[:1000])
        out_d1 = out_d2

    disass_path = os.path.join(OUT_DIR, "disass_2A_loop.txt")
    with open(disass_path, 'w', errors='replace') as f:
        f.write("$2A:$5596-$5640 disassembly:\n\n")
        f.write(out_d1)
    print("wrote", disass_path)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
