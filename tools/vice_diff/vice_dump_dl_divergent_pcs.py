"""Dump VICE x64sc memory + disasm focused on the v260 divergent IRQ-handler
PCs.

v260 finding (memory `project_dl_v260_irq_handler_divergence.md`):
- T65 IRQ-handler PC distribution: $83B4 / $89CB / $8596 / $802E / $8166 (5 even ~20%)
- VICE x64sc IRQ-handler PCs: $8100 / $8734 / $83BC / $8B3B (4 even ~25%)
- SCPU stuck on $8030 (32%) + $83B7 (26%) — two phases instead of 4-5

$8030 vs $802E = 2 bytes apart; $83B7 vs $83BC = 5 bytes apart. Same handler
regions, but the SCPU sample lands on slightly different fetch offsets. This
script disassembles a wide window around each divergent PC so we can see what
instructions live there and identify the branch that diverges.
"""

from __future__ import annotations
import socket, subprocess, sys, time
from pathlib import Path

VICE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\x64sc.exe"
PRG  = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
REU  = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
OUT  = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_divergent_pcs.txt"
PORT = 6510
PROMPT = b"(C:$"

# Each entry: (label, lo, hi). Wide windows so we see what surrounds the PC.
RANGES = [
    ("8000-80ff (SCPU $8030 / T65 $802E)", "8000", "80ff"),
    ("8300-83ff (SCPU $83B7 / T65 $83B4 / VICE $83BC)", "8300", "83ff"),
    ("8500-85ff (T65 $8596)", "8500", "85ff"),
    ("8700-87ff (VICE $8734)", "8700", "87ff"),
    ("8900-89ff (T65 $89CB)", "8900", "89ff"),
    ("8b00-8bff (VICE $8B3B)", "8b00", "8bff"),
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

        sock.sendall(b"\n")
        expect_prompt(sock, timeout=5.0)
        sock.sendall(b"\n")
        expect_prompt(sock, timeout=5.0)
        print("[paused]")

        out = Path(OUT)
        with out.open("w", encoding="utf-8") as fh:
            fh.write("# DL divergent-PC disasm (x64sc oracle)\n")
            for label, lo, hi in RANGES:
                fh.write(f"\n=== {label} DISASM ===\n")
                resp = send_cmd(sock, f"d ${lo} ${hi}", drain=4.0)
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
