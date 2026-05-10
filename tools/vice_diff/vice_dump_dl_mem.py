"""Dump DL memory regions from x64sc to identify what code lives at the
SCPU-divergent JSR PCs ($8105/$880F/$8C14/$8CC3/$8907 per v2 ring data).

Connects to VICE monitor, settles DL, then sends `m <addr> <addr+N>`
to dump bytes, and `d <addr> <addr+N>` to dump disassembly.
"""

from __future__ import annotations
import socket, subprocess, sys, time
from pathlib import Path

VICE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\x64sc.exe"
PRG  = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
REU  = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
OUT  = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_mem_dump.txt"
PORT = 6510
PROMPT = b"(C:$"

# Regions of interest from v2 ring analysis (commit 33337c8)
RANGES = [
    ("0002-0003", "0002",  "0003"),    # JMP-indirect dispatch vector
    ("0040-0070", "0040",  "0070"),    # state-machine variables ($40 $44 $5C are gate)
    ("0079-008b", "0079",  "008b"),    # IRQ stub (per memory)
    ("3300-33ff", "3300",  "33ff"),    # dispatcher
    ("8100-81ff", "8100",  "81ff"),    # SCPU-dominant JSR target
    ("8800-88ff", "8800",  "88ff"),    # SCPU-dominant JSR target
    ("8900-89ff", "8900",  "89ff"),    # SCPU-dominant JSR target
    ("8b00-8bff", "8b00",  "8bff"),    # SCPU-dominant JSR target
    ("8c00-8cff", "8c00",  "8cff"),    # SCPU-dominant JSR target
    ("8d00-8dff", "8d00",  "8dff"),    # $8D34 = top callee from $8105
    ("3000-31ff", "3000",  "31ff"),    # FLI body (T65 hits, SCPU misses)
    ("3200-32ff", "3200",  "32ff"),    # JMP $3200 target from $3300 dispatcher
    ("8500-85ff", "8500",  "85ff"),    # T65 vblank-PC, SCPU misses
    ("1f00-1fff", "1f00",  "1fff"),    # JMP $1F4E = T65's game-advance target
    ("8f00-8fff", "8f00",  "8fff"),    # $8F2B = where wait-loop escape jumps
    ("9700-99ff", "9700",  "99ff"),    # SCPU vblank-PC clustering (ROM mirror)
    ("1700-19ff", "1700",  "19ff"),    # SCPU vblank-PC clustering (RAM)
    ("8200-82ff", "8200",  "82ff"),    # JSR $8200 from $8F32 setup
    ("8e00-8eff", "8e00",  "8eff"),    # JSR $8EC7 from $8F35
    ("0044-0048", "0044",  "0048"),    # check $45 specifically
    ("0045-0046", "0045",  "0046"),    # $0045 is the wait-loop variable
]

def expect_prompt(sock, timeout=5.0):
    sock.settimeout(timeout)
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        if PROMPT in buf:
            return buf
    return buf

def send_cmd(sock, cmd, drain=2.0):
    sock.sendall((cmd + "\n").encode())
    return expect_prompt(sock, timeout=drain).decode(errors="replace")

def main() -> int:
    vice_args = [
        VICE, "-autostart", PRG, "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{PORT}",
        "-reu", "-reusize", "16384", "-reuimage", REU, "+reuimagerw",
        "-warp", "-silent",
    ]
    print(f"[launch] x64sc")
    proc = subprocess.Popen(vice_args)
    sock = None
    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", PORT), timeout=2.0)
                break
            except OSError:
                time.sleep(0.5)
        if sock is None:
            print("error: could not connect")
            return 2
        expect_prompt(sock, timeout=10.0)
        sock.sendall(b"x\n")
        print(f"[run] settling 25s...")
        time.sleep(25.0)

        # interrupt
        sock.sendall(b"\n")
        expect_prompt(sock, timeout=5.0)
        sock.sendall(b"\n")
        expect_prompt(sock, timeout=5.0)
        print("[paused]")

        out = Path(OUT)
        with out.open("w", encoding="utf-8") as fh:
            fh.write("# DL memory + disasm dump (x64sc, settled DL)\n")
            for label, lo, hi in RANGES:
                fh.write(f"\n=== {label} BYTES ===\n")
                resp = send_cmd(sock, f"m ${lo} ${hi}", drain=2.0)
                fh.write(resp)
                fh.write(f"\n=== {label} DISASM ===\n")
                resp = send_cmd(sock, f"d ${lo} ${hi}", drain=3.0)
                fh.write(resp)
                fh.flush()

        print(f"[done] wrote {OUT}")
    finally:
        if sock:
            try: sock.close()
            except OSError: pass
        try: proc.terminate()
        except Exception: pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
