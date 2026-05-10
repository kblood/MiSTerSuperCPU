#!/usr/bin/env python3
"""Sample VICE Doom's PB (program-bank register) over 60s of run.

VICE's `break exec` only matches bank $00 (16-bit address context).
So we can't catch bank-$2C executions via breakpoints. Instead:
pause → sample PB+PC → resume, every 0.5s for 60s.

Hardware halts in bank $2C ($2C:$A95C self-loop). If VICE NEVER
reaches PB=$2C during normal Doom execution, the error-handler bank
is unreachable in VICE's run → divergence is upstream of $2C entry.

Output: tools/doom_vice_pb_sample/result.txt — bank distribution.
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_pb_sample"
PORT     = 6510
PROMPT   = b"(C:$"


def expect_prompt(s, timeout=5.0):
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


def cmd(s, line, timeout=5.0):
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

    # Sample PB+PC every ~0.5s for 60s. To re-enter monitor, send `\r\n`,
    # which interrupts execution. Then `r` for register dump. Then `x` to resume.
    print("sampling PB+PC for 60s ...")
    samples = []
    end_t = time.time() + 60.0
    iter_n = 0
    while time.time() < end_t:
        iter_n += 1
        # Force into monitor (no-op if already in monitor; otherwise breaks)
        s.sendall(b"\r\n")
        time.sleep(0.05)
        drain(s, idle_s=0.2, max_s=0.5)
        out = cmd(s, "r", timeout=2)
        # Parse last .;XX YYYY line
        matches = re.findall(r"\.;([0-9a-f]{2})\s+([0-9a-f]{4})", out)
        if matches:
            pb, pc = matches[-1]
            samples.append((pb, pc))
            if iter_n <= 10 or iter_n % 20 == 0:
                print(f"  sample {iter_n}: PB=${pb} PC=${pc}")
        # Resume
        s.sendall(b"x\r\n")
        # Brief sleep so VICE actually runs between samples
        time.sleep(0.4)

    print(f"\ntotal samples: {len(samples)}")

    # Distribution by PB
    from collections import Counter
    pb_ctr = Counter(pb for pb, _ in samples)
    print("PB distribution:")
    for pb, n in sorted(pb_ctr.items(), key=lambda x: -x[1]):
        print(f"  PB=${pb}: {n}")

    # Check key banks
    pb_2c = pb_ctr.get("2c", 0)
    pb_2b = pb_ctr.get("2b", 0)
    pb_2a = pb_ctr.get("2a", 0)
    print(f"\nbank $2C samples: {pb_2c} (error handler bank)")
    print(f"bank $2B samples: {pb_2b} (bound-check / printer bank)")
    print(f"bank $2A samples: {pb_2a} (main code bank)")

    # Show first 30 samples for path visibility
    print("\nfirst 30 samples (PB:PC):")
    for pb, pc in samples[:30]:
        print(f"  ${pb}:${pc}")

    result = os.path.join(OUT_DIR, "result.txt")
    with open(result, 'w', errors='replace') as f:
        f.write("VICE Doom PB sampling (60s of warp after 30s autostart)\n")
        f.write("=" * 70 + "\n\n")
        f.write(f"Total samples: {len(samples)}\n\n")
        f.write("PB distribution:\n")
        for pb, n in sorted(pb_ctr.items(), key=lambda x: -x[1]):
            f.write(f"  PB=${pb}: {n}\n")
        f.write(f"\nbank $2C samples: {pb_2c} (HW error-handler bank)\n")
        f.write(f"bank $2B samples: {pb_2b} (bound-check/printer bank)\n")
        f.write(f"bank $2A samples: {pb_2a} (main code bank)\n\n")
        f.write("All samples (PB:PC):\n")
        for pb, pc in samples:
            f.write(f"  ${pb}:${pc}\n")

        f.write("\nInterpretation:\n")
        if pb_2c == 0 and pb_2b == 0:
            f.write("  ZERO samples in $2B or $2C. Either VICE is in PB=$2A only,\n")
            f.write("  or our pause-resume cadence is too coarse. Hardware halt is\n")
            f.write("  in PB=$2C, so absence here is suggestive that the error\n")
            f.write("  handler isn't reached in VICE.\n")
        elif pb_2c == 0:
            f.write(f"  VICE visits $2B ({pb_2b}x) but NOT $2C. The bound-check\n")
            f.write("  function in $2B runs, but its return doesn't fan into the\n")
            f.write("  error-handler bank $2C. Divergence point is the value\n")
            f.write("  passed to or returned from the bound check.\n")
        else:
            f.write(f"  VICE DOES visit $2C ({pb_2c}x). Need to compare which PCs\n")
            f.write("  in $2C and whether VICE returns from there cleanly while\n")
            f.write("  hardware halts.\n")
    print("wrote", result)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
