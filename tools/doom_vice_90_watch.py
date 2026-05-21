#!/usr/bin/env python3
"""Watch VICE for $F7-store to $0090 — does VICE EVER produce music_num=-9?

If VICE never writes $F7 to $00:$0090, then VICE's CPU never produces
the music_num=-9 sentinel. Hardware DOES (245 firings via $2B:$245A
printer arg-walker). The difference is the divergence we're hunting.

Use VICE 'watch' (memory watchpoint) on $0090 with conditional on data.
VICE remote monitor supports `watch store address [if condition]`.

Output: tools/doom_vice_90_watch/result.txt — list of (PC, value)
samples for any store of $F7 to $0090 in 90s of warp boot.
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_90_watch"
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
        if not ch:
            break
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
        if not ch:
            break
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
    s = None
    for attempt in range(30):
        time.sleep(1)
        try:
            s = socket.socket()
            s.settimeout(2)
            s.connect(("127.0.0.1", PORT))
            break
        except (socket.timeout, ConnectionRefusedError):
            s = None
    if not s:
        print("  ERROR: monitor never came up")
        p.terminate()
        return 1
    print("  monitor connected")
    drain(s, idle_s=0.5, max_s=2.0)

    # Set unconditional watch on $0090 stores. We'll filter for $F7
    # post-hoc from the monitor break output.
    print("  setting watch on $0090 stores ...")
    s.sendall(b"watch store 0090 0090\r\n")
    time.sleep(0.3)
    out = drain(s, idle_s=0.3, max_s=2.0)
    print("  >>>", out[-400:].decode(errors='replace'))

    # Resume; for each break, capture PC + accumulator (which holds the value
    # being stored), then continue.
    print("  resuming Doom for 90s warp; will collect break events ...")
    samples = []
    target_value_hits = []  # PCs where $F7 was the accumulator value
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    end_t = time.time() + 90.0
    buf = b""
    last_drain_t = time.time()
    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch:
            break
        buf += ch
        # Lines are typically: ".C:xxxx  85 90    STA $90    NNN" then prompt
        # Process completed lines
        text = buf.decode(errors='replace')
        if "(C:$" in text:
            # Have one or more break-prompt cycles to process
            parts = text.split("(C:$")
            for pr in parts[:-1]:
                # Within pr: look for "85 90" or "97 90" stores. Parse the .C:xxxx line.
                m = re.search(r"\.C:([0-9a-f]{4})\s+([0-9a-f]{2})\s+([0-9a-f]{2})", pr)
                if m:
                    pc = m.group(1)
                    op = m.group(2)
                    arg = m.group(3)
                    samples.append((pc, op, arg))
                    if len(samples) <= 5 or len(samples) % 50 == 0:
                        print(f"    sample {len(samples)}: pc={pc} op={op} arg={arg}")
                # Get accumulator. Send 'r' to dump regs.
            # Reset buf to last (incomplete) part
            buf = ("(C:$" + parts[-1]).encode()
        # Resume after each break event
        if PROMPT in buf:
            s.sendall(b"x\r\n")
            buf = b""

    print(f"  collected {len(samples)} watch-fire samples in 90s")
    # Force into monitor for final state
    time.sleep(1)
    s.sendall(b"\r\n")
    drain(s, idle_s=0.5, max_s=4.0)

    # Final reg dump
    out_r = cmd(s, "r", timeout=10)
    print("  registers:", out_r[:200])

    # Final $90-$93 dump
    out_zp = cmd(s, "m 0090 0093", timeout=5)
    print("  $90-$93:", out_zp[:120])

    result = os.path.join(OUT_DIR, "result.txt")
    with open(result, 'w', errors='replace') as f:
        f.write("VICE Doom $0090 store watch (90s warp)\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"total break events: {len(samples)}\n\n")
        # Tally (pc, opcode) frequency
        from collections import Counter
        pc_counter = Counter((pc, op) for pc, op, arg in samples)
        f.write("Top writer PCs (top 20):\n")
        for (pc, op), n in pc_counter.most_common(20):
            f.write(f"  pc=${pc} op=${op}  count={n}\n")
        f.write("\nFinal registers:\n" + out_r + "\n")
        f.write("\nFinal $90-$93:\n" + out_zp + "\n")
        f.write("\nFirst 50 samples:\n")
        for pc, op, arg in samples[:50]:
            f.write(f"  pc=${pc} op=${op} arg=${arg}\n")
    print("  wrote", result)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
