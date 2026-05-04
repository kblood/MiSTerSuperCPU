#!/usr/bin/env python3
"""Run Doom in xscpu64, break at $00:$0E0C, dump c64 bank $00 to file.

Memory says hardware Doom JMLs to $00:$0E0C and BRK-cascades because page
$0E is empty in c64 RAM. VICE works with the same loader.prg+doom.reu, so
its RAM at that breakpoint shows what Doom code SHOULD have populated.

Output: tools/doom_v274/vice_bank00.bin (full 64KB bank $00).
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\doom_loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_v274"
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

    # Launch VICE
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
    print("Launching VICE: " + " ".join(args[:1] + ['<args...>']))
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("  pid=" + str(p.pid))

    # Wait for monitor port to come up
    s = None
    for attempt in range(30):
        time.sleep(1)
        try:
            s = socket.socket()
            s.settimeout(2)
            s.connect(("127.0.0.1", PORT))
            break
        except (socket.timeout, ConnectionRefusedError) as e:
            s = None
            if attempt % 5 == 0:
                print("  waiting for monitor (attempt {})".format(attempt))

    if not s:
        print("  ERROR: monitor never came up")
        p.terminate()
        return 1

    print("  monitor connected")
    # Drain initial banner
    drain(s, idle_s=0.5, max_s=2.0)

    # Send a no-op to get a prompt; CPU is running so monitor may not respond
    # until paused. Force pause via 'r' (which triggers a break in older VICE,
    # or use 'stop' explicitly).
    s.sendall(b"\r\n")
    time.sleep(0.5)
    out = drain(s, idle_s=0.3, max_s=2.0)
    print("  initial drain: {} bytes".format(len(out)))
    print("  >>>", out[:200].decode(errors='replace').replace('\n', ' | '))

    # Try setting breakpoint while CPU runs (VICE allows this)
    # Then continue and wait for break.
    print("  setting breakpoint at $00:$0E0C ...")
    s.sendall(b"break 00:0e0c\r\n")
    time.sleep(0.5)
    out = drain(s, idle_s=0.3, max_s=2.0)
    print("  >>>", out[:300].decode(errors='replace').replace('\n', ' | ')[:300])

    # Continue execution and wait for breakpoint hit
    print("  continuing; waiting up to 60s for break at $0E0C")
    s.sendall(b"x\r\n")  # exit monitor (resume CPU)
    s.settimeout(60.0)
    buf = b""
    end = time.time() + 60.0
    hit = False
    while time.time() < end:
        try:
            ch = s.recv(65536)
        except socket.timeout:
            continue
        if not ch:
            break
        buf += ch
        if PROMPT in buf and b"BREAK" in buf.upper():
            hit = True
            break
        if PROMPT in buf:
            # Got a prompt without break, maybe broke for other reason
            hit = True
            break

    print("  break hit={}, buf len={}".format(hit, len(buf)))
    print("  last 400 bytes:", buf[-400:].decode(errors='replace'))

    if not hit:
        print("  Doom never reached $0E0C in VICE either. Checking VICE state...")
        # Force into monitor
        s.sendall(b"\r\n")
        time.sleep(1)
        drain(s, idle_s=0.5, max_s=3.0)
        cmd(s, "r")
        # Try to dump anyway
        pass

    # Dump bank $00 in chunks
    print("  dumping bank $00 c64 RAM...")
    bank0 = bytearray(0x10000)
    for chunk_start in range(0, 0x10000, 0x1000):
        end_addr = chunk_start + 0xFFF
        # 'm <start> <end>' in VICE monitor
        out = cmd(s, "m {:04x} {:04x}".format(chunk_start, end_addr), timeout=10)
        # Parse hex dump lines: ">C:0e00  78 d8 18 fb ..."
        for line in out.split('\n'):
            m = re.match(r'^>?\s*[CRMc]:([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2}\s+){1,16})', line)
            if m:
                base = int(m.group(1), 16)
                hex_bytes = m.group(2).split()
                for i, hb in enumerate(hex_bytes):
                    if base + i < 0x10000:
                        bank0[base + i] = int(hb, 16)

    out_path = os.path.join(OUT_DIR, "vice_bank00.bin")
    with open(out_path, 'wb') as f:
        f.write(bank0)
    print("  wrote {} ({} bytes)".format(out_path, len(bank0)))
    nz_p0e = sum(1 for b in bank0[0x0E00:0x0F00] if b != 0)
    print("  page $0E non-zero bytes: {}/256".format(nz_p0e))
    print("  $0E0C-$0E1F: {}".format(' '.join('{:02x}'.format(b) for b in bank0[0x0E0C:0x0E20])))

    # Quit VICE
    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
