#!/usr/bin/env python3
"""Sample VICE Doom's zp state — focus on music/printer/dispatcher pointers.

Per project memory, music_num is at $0090 (or $90/$92 16-bit). $94/$96
are bound-check args. $74-$76 is the JML[$74] dispatcher pointer ($A95C
trap on hardware, $A0:$9485 valid in VICE).

Sample these every 0.5s for 30s + record state.
Output: tools/doom_vice_zp_state/result.txt
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_zp_state"
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


def parse_mem_bytes(text):
    """Return dict[addr] = byte from 'm' command output."""
    result = {}
    for line in text.split("\n"):
        m = re.match(r"\s*\>?C:([0-9a-fA-F]{4})\s+(.*)$", line)
        if m:
            base = int(m.group(1), 16)
            rest = m.group(2)
            mb = re.match(r"((?:[0-9a-fA-F]{2}\s*)+)", rest)
            if not mb: continue
            for i, hb in enumerate(mb.group(1).split()):
                try:
                    result[base + i] = int(hb, 16)
                except ValueError:
                    pass
    return result


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    args = [VICE_EXE, "-reu", "-reusize", "16384", "+reuimagerw",
            "-reuimage", DOOM_REU, "-autostartprgmode", "1",
            "-autostart", DOOM_LDR, "-remotemonitor",
            "-remotemonitoraddress", f"127.0.0.1:{PORT}",
            "-warp", "+sound"]
    print("Launching VICE")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(30)
    s = None
    for _ in range(10):
        try:
            s = socket.socket(); s.settimeout(3); s.connect(("127.0.0.1", PORT)); break
        except (socket.timeout, ConnectionRefusedError):
            s = None; time.sleep(1)
    if not s: print("ERROR"); p.terminate(); return 1
    drain(s)

    samples = []
    iter_n = 0
    end_t = time.time() + 30.0
    while time.time() < end_t:
        iter_n += 1
        # Force into monitor
        s.sendall(b"\r\n")
        time.sleep(0.05)
        drain(s, idle_s=0.2, max_s=0.5)

        # zp $0070-$009F (covers $74, $88-$98)
        out_zp = cmd(s, "m $0070 $009f", timeout=3)
        # CPU regs
        out_r = cmd(s, "r", timeout=3)

        zpd = parse_mem_bytes(out_zp)
        # PB:PC from regs
        rm = re.search(r"\.;([0-9a-f]{2})\s+([0-9a-f]{4})", out_r)
        pb_pc = (rm.group(1), rm.group(2)) if rm else (None, None)

        # Pull values
        def val16(a):
            return zpd.get(a, 0) | (zpd.get(a+1, 0) << 8)
        def val24(a):
            return zpd.get(a, 0) | (zpd.get(a+1, 0) << 8) | (zpd.get(a+2, 0) << 16)
        rec = {
            "iter": iter_n, "pb": pb_pc[0], "pc": pb_pc[1],
            "z74": val24(0x74),  # dispatcher ptr
            "z88": val24(0x88),  # long ptr 1
            "z90": val16(0x90),  # music_num
            "z92": val16(0x92),
            "z94": val16(0x94),  # bound-check arg lo
            "z96": val16(0x96),  # bound-check arg hi
            "z98": val24(0x98),  # long ptr 2
        }
        samples.append(rec)
        if iter_n <= 8 or iter_n % 10 == 0:
            print(f"  s{iter_n}: PB=${rec['pb']} PC=${rec['pc']} | "
                  f"$74=${rec['z74']:06x} $90=${rec['z90']:04x} "
                  f"$94=${rec['z94']:04x} $96=${rec['z96']:04x} "
                  f"$88=${rec['z88']:06x} $98=${rec['z98']:06x}")
        # Resume
        s.sendall(b"x\r\n")
        time.sleep(0.5)

    # Distribution: unique values per slot
    from collections import Counter
    print(f"\ntotal samples: {len(samples)}")

    def dist(key):
        c = Counter(rec[key] for rec in samples)
        for v, n in c.most_common(8):
            print(f"  ${v:06x}  n={n}")

    print("\n$74 (dispatcher) distribution:"); dist("z74")
    print("\n$90 (music_num?) distribution:"); dist("z90")
    print("\n$94 (bound lo) distribution:"); dist("z94")
    print("\n$96 (bound hi) distribution:"); dist("z96")
    print("\n$88 (long ptr 1) distribution:"); dist("z88")
    print("\n$98 (long ptr 2) distribution:"); dist("z98")

    with open(os.path.join(OUT_DIR, "result.txt"), 'w', errors='replace') as f:
        f.write("VICE Doom zp $70-$9F state samples\n" + "="*60 + "\n\n")
        f.write(f"total samples: {len(samples)}\n\n")
        f.write("All samples:\n")
        for rec in samples:
            f.write(f"  s{rec['iter']:>3}: PB=${rec['pb']} PC=${rec['pc']} | "
                    f"$74=${rec['z74']:06x} $88=${rec['z88']:06x} "
                    f"$90=${rec['z90']:04x} $92=${rec['z92']:04x} "
                    f"$94=${rec['z94']:04x} $96=${rec['z96']:04x} "
                    f"$98=${rec['z98']:06x}\n")
    print("wrote result")

    cmd(s, "quit", timeout=2)
    s.close(); time.sleep(1); p.terminate()
    return 0


if __name__ == '__main__': sys.exit(main())
