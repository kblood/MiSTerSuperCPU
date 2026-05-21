#!/usr/bin/env python3
"""Does VICE Doom EVER execute in bank $2C error-handler region?

Sets 16-bit breakpoints at $85A1 and $A95C (both addresses on the
hardware halt PC ring). For each fire, captures PB to determine
which bank's $85A1/$A95C was reached.

Hardware path: $2C:$85A1 -> $85B6 -> $85E8 -> $85F6 -> $A95C halt.
If VICE never breaks, or breaks only with PB != $2C, the divergence
is upstream of the error handler — VICE's bound check returns to a
DIFFERENT (valid) entry in the music function-pointer table.

Output: tools/doom_vice_2c_path_check/result.txt + raw_monitor.txt
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_2c_path_check"
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
    raw_path = os.path.join(OUT_DIR, "raw_monitor.txt")
    raw_f = open(raw_path, 'w', errors='replace')

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

    # 30s warp boot WITHOUT monitor connection (autostart needs uninterrupted run)
    print("waiting 30s for VICE warp + Doom autostart ...")
    time.sleep(30)

    s = None
    for _ in range(10):
        try:
            s = socket.socket()
            s.settimeout(3)
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
    drain_buf = drain(s, idle_s=0.5, max_s=3.0)
    raw_f.write(drain_buf.decode(errors='replace'))

    # Confirm boot state
    out_r = cmd(s, "r", timeout=5)
    raw_f.write(out_r)
    print("  boot state:", out_r[:240])

    # Set both breakpoints
    print("setting break exec $85a1 + $a95c ...")
    out_b1 = cmd(s, "break exec $85a1", timeout=10)
    raw_f.write(out_b1)
    out_b2 = cmd(s, "break exec $a95c", timeout=10)
    raw_f.write(out_b2)
    print("  break list:", out_b1[-200:].strip(), "|", out_b2[-200:].strip())

    # Resume; collect break events for 60s
    print("resuming Doom for 60s warp; logging all break events ...")
    s.sendall(b"x\r\n")
    s.settimeout(2.0)

    # Track per-fire info: time, raw text, parsed PB+PC
    events = []
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
        raw_f.write(ch.decode(errors='replace'))
        raw_f.flush()
        if PROMPT in buf:
            text = buf.decode(errors='replace')
            # Find the LAST .;XX YYYY line (most recent reg dump in this prompt cycle)
            # Format varies by M/X flags so we match more loosely
            matches = re.findall(r"\.;([0-9a-f]{2})\s+([0-9a-f]{4})", text)
            if matches:
                pb, pc = matches[-1]
                events.append((time.time(), pb, pc))
                if len(events) <= 20 or len(events) % 25 == 0:
                    print(f"  break #{len(events)}: PB=${pb} PC=${pc}")
            # Resume
            s.sendall(b"x\r\n")
            buf = b""

    print(f"\ntotal break events: {len(events)}")

    # Bin by (PB, PC) — distinguishes $85A1 vs $A95C and which bank
    from collections import Counter
    addr_ctr = Counter((pb, pc) for _, pb, pc in events)
    print(f"(PB, PC) distribution:")
    for (pb, pc), n in sorted(addr_ctr.items(), key=lambda x: -x[1]):
        print(f"  PB=${pb} PC=${pc}  n={n}")

    # Force into monitor
    s.sendall(b"\r\n")
    time.sleep(1)
    drain_buf = drain(s, idle_s=0.5, max_s=3.0)
    raw_f.write(drain_buf.decode(errors='replace'))
    out_r = cmd(s, "r", timeout=5)
    raw_f.write(out_r)
    print("final regs:", out_r[:240])

    # Was the trap reached?
    pb_2c_85a1 = addr_ctr.get(("2c", "85a1"), 0)
    pb_2c_a95c = addr_ctr.get(("2c", "a95c"), 0)
    pb_85a1_any = sum(n for (pb, pc), n in addr_ctr.items() if pc == "85a1")
    pb_a95c_any = sum(n for (pb, pc), n in addr_ctr.items() if pc == "a95c")

    result = os.path.join(OUT_DIR, "result.txt")
    with open(result, 'w', errors='replace') as f:
        f.write("VICE Doom $2C error-handler path check (60s warp after 30s boot)\n")
        f.write("=" * 70 + "\n\n")
        f.write(f"Total break events: {len(events)}\n\n")
        f.write(f"$2C:$85A1 hits: {pb_2c_85a1}\n")
        f.write(f"$2C:$A95C hits: {pb_2c_a95c}  (the hardware self-loop trap)\n")
        f.write(f"$85A1 (any bank): {pb_85a1_any}\n")
        f.write(f"$A95C (any bank): {pb_a95c_any}\n\n")
        f.write("(PB, PC) distribution:\n")
        for (pb, pc), n in sorted(addr_ctr.items(), key=lambda x: -x[1]):
            f.write(f"  PB=${pb} PC=${pc}  n={n}\n")
        f.write("\nFinal registers:\n" + out_r + "\n")

        f.write("\nInterpretation:\n")
        if pb_2c_a95c > 0:
            f.write("  VICE REACHES $2C:$A95C (the hardware trap). Divergence is\n")
            f.write("  AT or DOWNSTREAM of $A95C — VICE somehow returns from it,\n")
            f.write("  hardware halts.\n")
        elif pb_2c_85a1 > 0:
            f.write(f"  VICE reaches $2C:$85A1 ({pb_2c_85a1}x) but NOT $A95C.\n")
            f.write("  Divergence is in the $85A1->$85B6->$85E8->$85F6->$A95C chain.\n")
        elif pb_85a1_any > 0 or pb_a95c_any > 0:
            f.write(f"  Hits at $85A1/$A95C but NOT in PB=$2C:\n")
            for (pb, pc), n in sorted(addr_ctr.items(), key=lambda x: -x[1]):
                f.write(f"    PB=${pb} PC=${pc}  n={n}\n")
            f.write("  Coincidental addresses in other banks; not the hardware\n")
            f.write("  error-handler code path.\n")
        else:
            f.write("  ZERO hits at $85A1 OR $A95C in any bank.\n")
            f.write("  -> Divergence is UPSTREAM of the error handler. VICE's\n")
            f.write("     execution path NEVER fans into the music_num error\n")
            f.write("     branch. The bound-check function ($2B:$DB90) returns\n")
            f.write("     to a DIFFERENT (valid) entry in the music function-\n")
            f.write("     pointer table. Hunt narrows to: what value does our\n")
            f.write("     P65C816 produce that VICE doesn't, that gets used as\n")
            f.write("     the music_num table index, that selects the error\n")
            f.write("     handler entry?\n")
    print("wrote", result)
    print("raw monitor log:", raw_path)

    cmd(s, "quit", timeout=2)
    s.close()
    raw_f.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
