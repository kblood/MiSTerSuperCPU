#!/usr/bin/env python3
"""Dump VICE $00:$FF00-$FFFF in full + parse trampolines."""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_full_ff_dump"
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
    if not s:
        print("ERROR"); p.terminate(); return 1

    # Dump $FF00-$FFFF in 32-byte chunks
    chunks = []
    for base in range(0xFF00, 0x10000, 0x20):
        out = cmd(s, f"m ${base:04x} ${base+0x1f:04x}", timeout=5)
        chunks.append((base, out))

    # Parse all hex bytes and reconstruct $FF00-$FFFF as one bytearray
    mem = bytearray(0x100)
    parsed = 0
    for base, text in chunks:
        for line in text.split("\n"):
            mre = re.match(r"\s*\>?C:([0-9a-fA-F]{4})\s+(.*)$", line)
            if mre:
                addr = int(mre.group(1), 16)
                if addr < 0xFF00 or addr >= 0x10000: continue
                # Strip the trailing ASCII gutter (after run of spaces+printable)
                # The hex bytes section ends at the first sequence of 3+ spaces.
                rest = mre.group(2)
                m2 = re.match(r"((?:[0-9a-fA-F]{2}\s*)+)", rest)
                if not m2: continue
                hbytes = m2.group(1).split()
                for i, hb in enumerate(hbytes):
                    try:
                        b = int(hb, 16)
                        if 0xFF00 <= addr+i < 0x10000:
                            mem[(addr+i) - 0xFF00] = b
                            parsed += 1
                    except ValueError:
                        pass

    print(f"parsed {parsed} bytes")
    # Show as hex grid
    print("\n$00:$FF00-$FFFF in VICE Doom:")
    for row in range(0, 0x100, 16):
        addr = 0xFF00 + row
        print(f"  ${addr:04x}: " + " ".join(f"{mem[row+i]:02x}" for i in range(16)))

    # Find trampolines: for each address Doom calls (FF00, FF22, FF5C, FF8E, FFA9, FFFF)
    callers = [0x00, 0x22, 0x5C, 0x8E, 0xA9, 0xFF]
    print("\nTrampoline contents:")
    for off in callers:
        # Show 16 bytes from this offset
        snippet = bytes(mem[off:off+16])
        print(f"  $FF{off:02X}: " + " ".join(f"{b:02x}" for b in snippet))

    # Save raw + dump
    with open(os.path.join(OUT_DIR, "ff_page.bin"), 'wb') as f:
        f.write(bytes(mem))

    with open(os.path.join(OUT_DIR, "result.txt"), 'w') as f:
        f.write("VICE Doom $00:$FF00-$FFFF dump\n" + "="*60 + "\n\n")
        for row in range(0, 0x100, 16):
            addr = 0xFF00 + row
            f.write(f"${addr:04x}: " + " ".join(f"{mem[row+i]:02x}" for i in range(16)) + "\n")
        f.write("\nTrampoline contents:\n")
        for off in callers:
            snippet = bytes(mem[off:off+16])
            f.write(f"  $FF{off:02X}: " + " ".join(f"{b:02x}" for b in snippet) + "\n")

    cmd(s, "quit", timeout=2)
    s.close(); time.sleep(1); p.terminate()
    return 0

if __name__ == '__main__': sys.exit(main())
