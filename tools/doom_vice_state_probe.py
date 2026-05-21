#!/usr/bin/env python3
"""Probe VICE Doom state — confirm graphics mode + capture $0074-$0076.

Hardware halts via JML[$0074] -> $2C:$A95C with "Bad music number -9"
printed in text mode. If VICE is in graphics mode and $0074-$0076 doesn't
point at $2C:$A95C, that's the divergence.

Captures from VICE Doom after 60s warp boot:
- $D018, $D011 (VIC mode select)
- $0074-$0076 (dispatch ptr)
- $0090-$009F (music_num and surrounding zp)
- $0086-$008B (relevant printer/dispatcher zp)
- 16 bytes around the M: ring PCs ($2C:$85A1, $85B6, $85E8, $85F6, $A95C)
- monitor `r` register dump (PC + flags)
"""
import os, sys, socket, subprocess, time, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
DOOM_REU = r"C:\LLM\C64\MiSTerSuperCPU\doom.reu"
DOOM_LDR = r"C:\LLM\C64\MiSTerSuperCPU\loader.prg"
OUT_DIR  = r"C:\LLM\C64\MiSTerSuperCPU\tools\doom_vice_state"
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

    # Resume CPU and let Doom run for 60s
    print("  resuming Doom for 90s warp ...")
    s.sendall(b"x\r\n")
    time.sleep(90)

    # Force into monitor (send any line + drain). xscpu64 monitor uses
    # signal-based break: send 'break' command line, but if running, the
    # monitor command must come via stdin -- which is what the socket is.
    # Reading the monitor source: any unrecognized command while running
    # should return to monitor when the next checkpoint fires. Easier:
    # use 'until' or 'g' which return on completion. Alternative: send a
    # newline; if we see a prompt, we're paused.
    print("  attempting to enter monitor ...")
    s.sendall(b"\r\n")
    out = drain(s, idle_s=0.5, max_s=4.0)
    print("  drain after newline:", out[-200:].decode(errors='replace'))

    if PROMPT not in out:
        # CPU is running; need to force monitor entry. xscpu64 supports
        # the "monitor open" command via the keyboard signal. Try sending
        # ESC + Enter, or use 'r' (registers) as a query that auto-pauses
        # on some VICE versions.
        # Actually, with -remotemonitor, the monitor stays attached; the
        # 'x' command resumes, and any incoming text from us re-enters.
        # Possibly we need to wait longer. Try sending 'r' and see.
        out2 = cmd(s, "r", timeout=10)
        print("  r-cmd response (first 300):", out2[:300])

    # Register state
    out_r = cmd(s, "r", timeout=10)
    print("  registers:", out_r[:300])

    # VIC state -- $D011, $D016, $D018, $DD00
    out_vic = cmd(s, "m d010 d020", timeout=8)
    out_dd00 = cmd(s, "m dd00 dd02", timeout=5)

    # Zero page key locations
    out_zp7x = cmd(s, "m 0070 0080", timeout=5)
    out_zp8x = cmd(s, "m 0080 0098", timeout=5)
    out_zp9x = cmd(s, "m 0090 00a0", timeout=5)

    # Bank $2C halt PCs (if reachable)
    pcs = [(0x2c, 0x85a0, 0x85b0), (0x2c, 0x85e0, 0x85f0), (0x2c, 0x85f0, 0x8600), (0x2c, 0xa950, 0xa970)]
    bank_dumps = []
    for bank, lo, hi in pcs:
        try:
            out_b = cmd(s, "m {:02x}{:04x} {:02x}{:04x}".format(bank, lo, bank, hi), timeout=8)
        except Exception as e:
            out_b = "ERR " + str(e)
        bank_dumps.append((bank, lo, hi, out_b))

    # Try alternate banked memory syntax
    out_alt1 = cmd(s, "m c:2ca950 c:2ca970", timeout=5)
    out_alt2 = cmd(s, "bank 2c", timeout=5)
    out_alt3 = cmd(s, "m a950 a970", timeout=5)

    result_path = os.path.join(OUT_DIR, "result.txt")
    with open(result_path, 'w', errors='replace') as f:
        f.write("VICE Doom state probe (after 90s warp boot)\n")
        f.write("=" * 60 + "\n\n")
        f.write("Registers:\n" + out_r + "\n\n")
        f.write("VIC $D010-$D01F:\n" + out_vic + "\n")
        f.write("CIA2 $DD00-$DD02:\n" + out_dd00 + "\n")
        f.write("\nZP $0070-$007F (incl $74-$76 dispatch ptr):\n" + out_zp7x + "\n")
        f.write("ZP $0080-$0097 (printer args):\n" + out_zp8x + "\n")
        f.write("ZP $0090-$009F (music_num):\n" + out_zp9x + "\n")
        f.write("\n--- Halt PC ring bank dumps (24-bit addr probe) ---\n")
        for bank, lo, hi, out_b in bank_dumps:
            f.write("$%02x:$%04x..$%04x:\n%s\n" % (bank, lo, hi, out_b))
        f.write("\nAlt syntax c:2ca950 c:2ca970:\n" + out_alt1 + "\n")
        f.write("\nbank command:\n" + out_alt2 + "\n")
        f.write("\nm a950 a970 (bank 0):\n" + out_alt3 + "\n")
    print("  wrote " + result_path)

    cmd(s, "quit", timeout=2)
    s.close()
    time.sleep(2)
    p.terminate()
    return 0


if __name__ == '__main__':
    sys.exit(main())
