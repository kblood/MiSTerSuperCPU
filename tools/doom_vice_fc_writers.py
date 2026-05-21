#!/usr/bin/env python3
"""Watch writes to $00:$00FC-$FE in VICE Doom — find who installs the
dispatcher pointer that's wrong on hardware.

VICE: $FC/$FD/$FE = $85,$94,$A0 (jump target $A0:$9485 — valid Doom code)
Hardware: $FC/$FD/$FE = $5C,$A9,$2C (jump target $2C:$A95C — error trap)

The hardware values are stale loader values. Doom is supposed to OVERWRITE
$FC-$FE with valid handler addresses but doesn't on hardware. By watching
VICE's writers, we find which Doom function is supposed to run.

Output: tools/doom_vice_fc_writers/result.txt
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\doom_loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_fc_writers"
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
    # Connect EARLY so we catch boot writes too
    time.sleep(3)
    s = None
    for _ in range(30):
        try:
            s = socket.socket(); s.settimeout(2); s.connect(("127.0.0.1", PORT)); break
        except (socket.timeout, ConnectionRefusedError):
            s = None; time.sleep(1)
    if not s: print("ERROR"); p.terminate(); return 1
    print("monitor connected (early)")
    drain(s, idle_s=0.5, max_s=2.0)

    # Set watch on $0074-$0076 AND $00FC-$00FE
    print("setting watch store $00fc $00fe ...")
    out1 = cmd(s, "watch store $00fc $00fe", timeout=5)
    print("setting watch store $0074 $0076 ...")
    out2 = cmd(s, "watch store $0074 $0076", timeout=5)
    print("  >>>", out1.strip()[-150:], "|", out2.strip()[-150:])

    raw_path = os.path.join(OUT_DIR, "raw.txt")
    raw_f = open(raw_path, 'w', errors='replace')
    raw_f.write(out1 + out2)

    # Resume; capture for 60s
    print("resuming for 60s warp; capturing ALL watch events ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    events = []
    end_t = time.time() + 60.0
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
        if PROMPT in buf:
            text = buf.decode(errors='replace')
            # Each watch hit emits a line + register dump
            # Look for watch identifier and register lines
            # Pattern: "#N (Watch on store at $00xx)"
            wm = re.search(r"#(\d+)\s*\(Watch on store .* (\$00[0-9a-fA-F]+)\)", text)
            target = wm.group(2) if wm else None
            # Reg line shows current PB:PC and accumulator (which is the value stored)
            rm = re.search(r"\.;([0-9a-fA-F]{2})\s+([0-9a-fA-F]{4})\s+([0-9a-fA-F]+)", text)
            if rm:
                pb, pc, a = rm.group(1), rm.group(2), rm.group(3)
                events.append((target, pb, pc, a))
                if len(events) <= 30 or len(events) % 20 == 0:
                    print(f"  ev{len(events):>3}: tgt={target} from PB=${pb} PC=${pc} A=${a}")
            s.sendall(b"x\r\n")
            buf = b""

    print(f"\ntotal watch events: {len(events)}")

    from collections import Counter
    pc_writers = Counter((pb, pc) for _, pb, pc, _ in events)
    print("\nWriter (PB:PC) frequency:")
    for (pb, pc), n in pc_writers.most_common(20):
        print(f"  ${pb}:${pc}  n={n}")

    # Per-target tally
    target_tally = Counter(t for t, _, _, _ in events)
    print("\nTargets:")
    for t, n in target_tally.most_common():
        print(f"  {t}: {n}")

    # Force monitor + dump current state
    s.sendall(b"\r\n")
    time.sleep(0.5)
    drain(s)
    out_zp = cmd(s, "m $0074 $0076", timeout=3)
    out_fc = cmd(s, "m $00fc $00fe", timeout=3)
    raw_f.write("\n--- final state ---\n" + out_zp + out_fc)
    print(f"\nfinal state - $74-$76:\n{out_zp}\nfinal - $FC-$FE:\n{out_fc}")

    with open(os.path.join(OUT_DIR, "result.txt"), 'w', errors='replace') as f:
        f.write("VICE Doom watch store $0074-$0076 + $00FC-$00FE (60s warp)\n")
        f.write("=" * 70 + "\n\n")
        f.write(f"total events: {len(events)}\n\n")
        f.write("Writer (PB:PC) frequency:\n")
        for (pb, pc), n in pc_writers.most_common():
            f.write(f"  ${pb}:${pc}  n={n}\n")
        f.write(f"\nTarget frequency:\n")
        for t, n in target_tally.most_common():
            f.write(f"  {t}: {n}\n")
        f.write(f"\nFinal $74-$76:\n{out_zp}\n")
        f.write(f"\nFinal $FC-$FE:\n{out_fc}\n")
        f.write(f"\nFirst 100 events (target, PB:PC, A):\n")
        for ev in events[:100]:
            f.write(f"  {ev}\n")
    print("wrote result")

    cmd(s, "quit", timeout=2)
    s.close(); raw_f.close(); time.sleep(1); p.terminate()
    return 0


if __name__ == '__main__': sys.exit(main())
