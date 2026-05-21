#!/usr/bin/env python3
"""Watch $0074 stores in VICE during Doom boot.

Hardware halts via JML[$0074] = $2C:$A95C. VICE Doom snapshot shows
$74-$76 = $85,$94,$A0 (= $A0:$9485 = different dispatch target). Use
VICE 'break store 0074' watchpoint to log each write to $0074. Compare
patterns with hardware writer-PC capture.

Output: tools/doom_vice_74_watch/result.txt
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_74_watch"
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

    # Periodic snapshot of $74-$76 over 60s
    print("  resuming Doom; will sample $74-$76 every 10s")
    s.sendall(b"x\r\n")  # resume

    samples = []
    for i in range(8):
        time.sleep(10)
        # Force monitor entry
        s.sendall(b"\r\n")
        out = drain(s, idle_s=0.3, max_s=2.0)
        # Get registers
        out_r = cmd(s, "r", timeout=10)
        m_pc = re.search(r"\.;([0-9a-f]{2})\s+([0-9a-f]{4})", out_r)
        if m_pc:
            pb, pc = m_pc.group(1), m_pc.group(2)
        else:
            pb, pc = "??", "????"
        # Dump $74-$77
        out_zp = cmd(s, "m 0074 0077", timeout=5)
        m_zp = re.search(r"\$0074\s+([0-9a-f]{2})\s+([0-9a-f]{2})\s+([0-9a-f]{2})\s+([0-9a-f]{2})", out_zp, re.IGNORECASE)
        if not m_zp:
            m_zp = re.search(r"0074\s+([0-9a-f]{2})\s+([0-9a-f]{2})\s+([0-9a-f]{2})\s+([0-9a-f]{2})", out_zp, re.IGNORECASE)
        if m_zp:
            v74, v75, v76, v77 = m_zp.group(1), m_zp.group(2), m_zp.group(3), m_zp.group(4)
        else:
            v74 = v75 = v76 = v77 = "??"
        sample = "t=+{:3d}s  PB:{} PC:{}  $74-$77 = {} {} {} {}  (jmp[$74] -> bank ${} addr ${}{})".format(
            (i+1)*10, pb, pc, v74, v75, v76, v77, v76, v75, v74)
        print(" ", sample)
        samples.append(sample)
        # Resume
        s.sendall(b"x\r\n")

    # Final state — let break store fire
    s.sendall(b"\r\n")
    drain(s, idle_s=0.3, max_s=2.0)
    out_break = cmd(s, "watch store 74 74", timeout=5)
    print("  watchpoint set:", out_break[:200])
    # Resume briefly to log a few hits
    print("  resuming briefly to log $74 stores...")
    s.sendall(b"x\r\n")
    s.settimeout(15.0)
    buf = b""
    end_t = time.time() + 15.0
    while time.time() < end_t:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch:
            break
        buf += ch

    # Write report
    result = os.path.join(OUT_DIR, "result.txt")
    with open(result, 'w', errors='replace') as f:
        f.write("VICE Doom $74-$76 watch (10s sampling, 8 samples)\n")
        f.write("=" * 60 + "\n\n")
        for sample in samples:
            f.write(sample + "\n")
        f.write("\nWatchpoint trace (15s):\n")
        f.write(buf.decode(errors='replace')[-4000:])
    print("  wrote", result)
    print()
    print("Sample summary:")
    for sample in samples:
        print(" ", sample)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
