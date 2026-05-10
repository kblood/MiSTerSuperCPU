#!/usr/bin/env python3
"""Run Doom in xscpu64; check if it hits the same halt at $2C:$A95C as hardware.

Hardware halts via JML[$0074] -> $2C:$A95C self-loop after printing
"Bad music number -9". If VICE hits the same breakpoint, the bug is
Doom-internal (independent of our P65C816 core). If VICE doesn't,
something in our core diverges from VICE's CPU and we have a target.

Output: tools/doom_vice_halt_check/result.txt (hit=Y/N + screen dump
+ 16 bytes around expected halt addr).
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_halt_check"
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
    print("  pid=" + str(p.pid))

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
    s.sendall(b"\r\n")
    time.sleep(0.5)
    drain(s, idle_s=0.3, max_s=2.0)

    print("  setting breakpoint at $2C:$A95C ...")
    s.sendall(b"break 2C:a95c\r\n")
    time.sleep(0.5)
    out = drain(s, idle_s=0.3, max_s=2.0)
    print("  >>>", out[:200].decode(errors='replace').replace('\n', ' | ')[:200])

    print("  resuming Doom; waiting up to 240s for halt breakpoint")
    s.sendall(b"x\r\n")
    s.settimeout(240.0)
    buf = b""
    end = time.time() + 240.0
    hit = False
    while time.time() < end:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch:
            break
        buf += ch
        if b"BREAK" in buf.upper() and PROMPT in buf:
            hit = True
            break

    print("  hit=" + str(hit) + ", recv buf len=" + str(len(buf)))
    if buf:
        print("  last 300 bytes:", buf[-300:].decode(errors='replace'))

    # Force pause if not in monitor
    if not hit:
        print("  did NOT reach halt; forcing into monitor to inspect state")
        # Send any byte to force monitor entry; the monitor 'r' command works
        # while running on some VICE versions. Try escape sequence.
        s.sendall(b"\r\n")
        time.sleep(1.5)
        drain(s, idle_s=0.5, max_s=3.0)

    # Dump screen RAM ($0400-$07E7) to look for "BAD MUSIC NUMBER" text
    print("  dumping screen RAM ...")
    out = cmd(s, "m 0400 07e7", timeout=10)
    screen = bytearray(0x3E8)
    for line in out.split('\n'):
        m = re.match(r'^>?\s*[CRMc]:([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2}\s+){1,16})', line)
        if m:
            base = int(m.group(1), 16) - 0x0400
            if base < 0 or base >= 0x3E8:
                continue
            for i, hb in enumerate(m.group(2).split()):
                if base + i < 0x3E8:
                    screen[base + i] = int(hb, 16)

    # Convert screen-code bytes to ASCII (very rough)
    def sc_to_chr(b):
        if 0x01 <= b <= 0x1A:
            return chr(b - 0x01 + ord('A'))
        if 0x30 <= b <= 0x39:
            return chr(b)
        if b == 0x20: return ' '
        if b == 0x2D: return '-'
        if b == 0x2E: return '.'
        if b == 0x3A: return ':'
        if b == 0x3F: return '?'
        return '.'

    screen_text = ''.join(sc_to_chr(b) for b in screen)
    rows = [screen_text[i:i+40] for i in range(0, 0x3E8, 40)]

    # Dump 16 bytes at $2C:$A950 to see what halt looks like in VICE
    print("  dumping $2C:$A950..A95F ...")
    out_a95 = cmd(s, "m 2c:a950 2c:a95f", timeout=5)

    # Also peek $00:$0090..$93 zp
    out_zp = cmd(s, "m 0090 00a0", timeout=5)

    result_path = os.path.join(OUT_DIR, "result.txt")
    with open(result_path, 'w', errors='replace') as f:
        f.write("VICE Doom halt-breakpoint check at $2C:$A95C\n")
        f.write("=" * 60 + "\n")
        f.write("breakpoint hit:  " + ("YES (same halt as hardware)" if hit else "NO (divergence)") + "\n\n")
        f.write("Screen RAM (text):\n")
        for r in rows:
            f.write("  " + r + "\n")
        f.write("\n$2C:$A950..$A95F:\n" + out_a95 + "\n")
        f.write("\n$0090..$00A0:\n" + out_zp + "\n")
        f.write("\nRecv buf last 600 bytes:\n" + buf[-600:].decode(errors='replace') + "\n")
    print("  wrote " + result_path)
    print()
    print("=" * 60)
    print("HALT REACHED:", "YES" if hit else "NO")
    print("=" * 60)
    print("Screen RAM text (rows 0-24):")
    for i, r in enumerate(rows):
        if any(c not in ' .' for c in r):
            print("  {:2d}: {}".format(i, r))

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
