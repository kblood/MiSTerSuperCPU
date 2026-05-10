#!/usr/bin/env python3
"""Watch writes to $00:$FF00-$FF1F in VICE Doom.

Hypothesis: Doom dynamically installs trampoline bytes at $00:$FFxx
before calling them. Confirm by watching memory writes.

Sets `watch store $ff00 $ff1f` in VICE remote monitor, runs Doom for
30s warp, captures all break events.
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_ff00_watch"
PORT     = 6510
PROMPT   = b"(C:$"


def expect_prompt(s, timeout=10.0):
    s.settimeout(2.0)
    buf = b""
    end = time.time() + timeout
    last_t = time.time()
    while time.time() < end:
        try:
            ch = s.recv(65536); last_t = time.time()
        except socket.timeout:
            if PROMPT in buf and (time.time() - last_t) > 0.3:
                return buf
            continue
        if not ch: break
        buf += ch
    return buf


def cmd(s, line, timeout=10.0):
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
    args = [VICE_EXE, "-reu", "-reusize", "16384", "+reuimagerw",
            "-reuimage", DOOM_REU, "-autostartprgmode", "1",
            "-autostart", DOOM_LDR, "-remotemonitor",
            "-remotemonitoraddress", f"127.0.0.1:{PORT}",
            "-warp", "+sound"]
    print("Launching VICE")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(20)  # boot
    s = None
    for _ in range(10):
        try:
            s = socket.socket(); s.settimeout(3); s.connect(("127.0.0.1", PORT)); break
        except (socket.timeout, ConnectionRefusedError):
            s = None; time.sleep(1)
    if not s:
        print("ERROR"); p.terminate(); return 1
    drain(s)

    # Set memory write watchpoint on $FF00-$FF20
    print("setting watch store $ff00-$ff20 ...")
    out = cmd(s, "watch store $ff00 $ff20", timeout=5)
    print("  watch:", out[-200:])

    raw_path = os.path.join(OUT_DIR, "raw.txt")
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write(out)

    # Resume; collect break events for 30s
    print("resuming for 30s warp; collecting watch events ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    events = []
    end_t = time.time() + 30.0
    buf = b""
    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch: break
        buf += ch
        text_chunk = ch.decode(errors='replace')
        raw_f.write(text_chunk); raw_f.flush()
        # Each watch hit produces something like
        # "#1 (Watch on store)" + register dump + prompt
        if PROMPT in buf:
            text = buf.decode(errors='replace')
            # Look for `Watch ... store` events
            ms = re.findall(r"\.([0-9a-fA-F]{2}):([0-9a-fA-F]{4})\s+([0-9a-fA-F]{2})\s+([0-9a-fA-F]{2})", text)
            for pb, pc, op, arg in ms[-3:]:
                events.append((pb, pc, op, arg))
                if len(events) <= 30 or len(events) % 50 == 0:
                    print(f"  ev #{len(events)}: PB=${pb} PC=${pc} op={op} arg={arg}")
            s.sendall(b"x\r\n")
            buf = b""

    print(f"\ntotal events captured: {len(events)}")

    # Force monitor + dump $FF00-$FF1F state at end
    s.sendall(b"\r\n")
    time.sleep(1)
    drain(s)
    out_dump = cmd(s, "m $ff00 $ff1f", timeout=5)
    raw_f.write("\n--- final dump ---\n" + out_dump)
    print("\nfinal $00:$FF00-$FF1F:")
    print(out_dump)

    # Tally writer-PC distribution
    from collections import Counter
    pc_ctr = Counter((pb, pc) for pb, pc, _, _ in events)
    print("\nTop writer (PB:PC):")
    for (pb, pc), n in pc_ctr.most_common(15):
        print(f"  ${pb}:${pc}  n={n}")

    with open(os.path.join(OUT_DIR, "result.txt"), 'w', errors='replace') as f:
        f.write(f"VICE Doom watch store $00:$FF00-$FF20 (30s warp)\n" + "="*60 + "\n\n")
        f.write(f"total events: {len(events)}\n\n")
        f.write("writer (PB:PC) frequency:\n")
        for (pb, pc), n in pc_ctr.most_common():
            f.write(f"  ${pb}:${pc}  n={n}\n")
        f.write(f"\nfinal $00:$FF00-$FF1F:\n{out_dump}\n")
        f.write(f"\nfirst 80 events (PB,PC,op,arg):\n")
        for ev in events[:80]:
            f.write(f"  {ev}\n")
    print("wrote result")

    cmd(s, "quit", timeout=2)
    s.close(); raw_f.close(); time.sleep(1); p.terminate()
    return 0


if __name__ == '__main__': sys.exit(main())
