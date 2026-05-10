"""Snapshot VIC IRQ + sprite state from VICE xscpu64 running Dragon's Lair.

Compares against MiSTer SCPU v234 captures:
  T65:  RD=F1 EM=01 SB=F WR=F2  (working)
  SCPU: RD=F7 EM=01 SB=F WR=F8  (broken — extra sprite-collision IRQs)

We don't need streaming trace; one snapshot taken during stable gameplay
answers the diagnostic question:
  - If VICE shows RD=F1, T65 is the oracle and SCPU's $F7 is the bug.
  - If VICE shows RD=F7, DL legitimately produces sprite collisions on
    a working SuperCPU; the bug is somewhere else (cycle-count, ack
    handling, or upstream state).

Method: -autostart, settle in warp for N seconds, break monitor, dump
memory at the relevant VIC registers, print a tabular result.
"""

from __future__ import annotations

import argparse
import socket
import subprocess
import sys
import time
from pathlib import Path

VICE_EXE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
DEFAULT_PRG = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
DEFAULT_REU = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
DEFAULT_PORT = 6510
PROMPT = b"(C:$"


def drain(sock: socket.socket, idle_secs: float = 0.5, max_wait: float = 5.0) -> bytes:
    """Read until the socket is idle for `idle_secs` consecutive seconds."""
    sock.settimeout(idle_secs)
    buf = b""
    end = time.time() + max_wait
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            # idle reached
            break
    return buf


def cmd(sock: socket.socket, line: str, idle_secs: float = 0.4, max_wait: float = 5.0) -> str:
    """Send a command, then drain output until the socket goes idle.

    Uses idle-based draining instead of prompt-detection because VICE
    re-prints `(C:$XXXX)` prompts at irregular intervals and prompt
    detection races with multi-line responses.
    """
    # First, eat any unread output left from a prior command.
    drain(sock, idle_secs=0.05, max_wait=0.2)
    sock.sendall((line.rstrip() + "\n").encode())
    return drain(sock, idle_secs=idle_secs, max_wait=max_wait).decode(errors="replace")


def expect_prompt(sock: socket.socket, timeout: float = 5.0, max_wait: float = None) -> str:
    """Compatibility wrapper used early in setup; just drain."""
    if max_wait is None:
        max_wait = timeout
    return drain(sock, idle_secs=0.3, max_wait=max_wait).decode(errors="replace")


def parse_byte(monitor_out: str, addr: int) -> int | None:
    """Parse a `m $XXXX $XXXX` response for the byte at addr.

    VICE 3.9 prints lines like:
        >C:d000 ff fe ff fe ff fe ff fe   ........
        >C:d010 ff 27 ff 00 11 ff 18 f1   .'......
    Each line dumps 8 bytes starting at the line's address. We need
    to find which line contains addr and grab the right byte offset.
    """
    # VICE 3.9 prints 16-byte rows: ">C:d010  00 80 37 00  ...  00 00 00 00"
    base = addr & ~0x0F
    target_line = f"{base:04x}"
    for line in monitor_out.splitlines():
        s = line.strip().lower()
        if s.startswith(">"):
            s = s[1:].strip()
        if s.startswith("c:") and s[2:6] == target_line:
            rest = s[6:].strip()
            tokens = [t for t in rest.split() if len(t) == 2 and all(c in "0123456789abcdef" for c in t)]
            byte_idx = addr - base
            if byte_idx < len(tokens):
                try:
                    return int(tokens[byte_idx], 16)
                except ValueError:
                    pass
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prg", default=DEFAULT_PRG)
    ap.add_argument("--reu", default=DEFAULT_REU)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--settle-secs", type=float, default=30.0)
    ap.add_argument("--samples", type=int, default=4,
                    help="Take this many snapshots, 1s apart")
    args = ap.parse_args()

    for p in (VICE_EXE, args.prg, args.reu):
        if not Path(p).exists():
            print(f"error: missing {p}", file=sys.stderr)
            return 2

    vice_args = [
        VICE_EXE,
        "-autostart", args.prg,
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{args.port}",
        "-reu", "-reusize", "16384", "-reuimage", args.reu,
        "+reuimagerw", "-warp", "-silent",
    ]
    print(f"[launch] xscpu64 with REU image, warp, autostart")
    proc = subprocess.Popen(vice_args)

    sock = None
    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", args.port), timeout=2.0)
                break
            except OSError:
                time.sleep(0.5)
        if sock is None:
            print("error: could not connect", file=sys.stderr)
            return 2
        print("[ok] monitor connected")
        expect_prompt(sock, timeout=10.0)

        # Resume — autostart will run LOAD + RUN keystrokes
        sock.sendall(b"x\n")
        print(f"[run] settling for {args.settle_secs}s in warp...")
        time.sleep(args.settle_secs)

        # Break and dump VIC state
        for i in range(args.samples):
            if i > 0:
                # Resume between samples
                sock.sendall(b"x\n")
                time.sleep(1.0)
            sock.sendall(b"\n")  # break
            expect_prompt(sock, max_wait=3.0)

            # Dump $D015-$D02E (sprite + IRQ block, 26 bytes)
            out_d000 = cmd(sock, "m $d000 $d02f", max_wait=3.0)
            # Dump $DD00 (CIA2 PA, VIC bank select)
            out_dd00 = cmd(sock, "m $dd00 $dd07", max_wait=3.0)
            # Dump CPU registers (P65C816 register dump)
            out_r = cmd(sock, "r", max_wait=3.0)
            if i == 0:
                # Diagnostic: dump raw monitor output once so we can
                # see VICE 3.9's exact line format and tune the parser.
                Path(r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_snapshot_raw.log").write_text(
                    f"--- m $d000 $d02f ---\n{out_d000}\n"
                    f"--- m $dd00 $dd07 ---\n{out_dd00}\n"
                    f"--- r ---\n{out_r}\n",
                    encoding="utf-8",
                )

            # Extract bytes
            def byte(addr: int, src: str) -> str:
                v = parse_byte(src, addr)
                return f"{v:02x}" if v is not None else "??"

            d011 = byte(0xd011, out_d000)  # control1 / raster MSB
            d012 = byte(0xd012, out_d000)  # raster cmp LSB
            d015 = byte(0xd015, out_d000)  # sprite enable
            d016 = byte(0xd016, out_d000)  # control2
            d017 = byte(0xd017, out_d000)  # sprite Y expand
            d018 = byte(0xd018, out_d000)  # screen+char ptr
            d019 = byte(0xd019, out_d000)  # IRQ status (read = source latches)
            d01a = byte(0xd01a, out_d000)  # IRQ enable
            d01b = byte(0xd01b, out_d000)  # sprite-bg priority
            d01c = byte(0xd01c, out_d000)  # sprite multicolor
            d01d = byte(0xd01d, out_d000)  # sprite X expand
            d01e = byte(0xd01e, out_d000)  # sprite-sprite collision (RC)
            d01f = byte(0xd01f, out_d000)  # sprite-bg collision (RC)
            dd00 = byte(0xdd00, out_dd00)  # CIA2 PA

            # Find PC in register dump.
            pc = "?????"
            for line in out_r.splitlines():
                # format like:  ADDR  AC XR YR SP NV-BDIZC  LIN CYC  STOPWATCH
                s = line.strip()
                if s and s[0:1].isalnum() and len(s) >= 4:
                    parts = s.split()
                    if parts and len(parts[0]) == 4 and all(c in "0123456789abcdef" for c in parts[0].lower()):
                        pc = parts[0].lower()
                        break

            print(f"\n=== Sample {i+1} (PC={pc}) ===")
            print(f"  $D011={d011}  $D012={d012}  $D015={d015}  $D016={d016}")
            print(f"  $D017={d017}  $D018={d018}  $D019={d019}  $D01A={d01a}")
            print(f"  $D01B={d01b}  $D01C={d01c}  $D01D={d01d}")
            print(f"  $D01E={d01e}  $D01F={d01f}  $DD00={dd00}")
            print(f"  -> DD00 (VIC bank): { ('00','01','02','03')[ (int(dd00,16)&3) ] if dd00!='??' else '??' }")
            print(f"  -> D019 source bits: ILP={int(d019,16)>>3&1 if d019!='??' else '?'} "
                  f"IMMC={int(d019,16)>>2&1 if d019!='??' else '?'} "
                  f"IMBC={int(d019,16)>>1&1 if d019!='??' else '?'} "
                  f"IRST={int(d019,16)&1 if d019!='??' else '?'}")
            print(f"  -> D01A enable bits: ELP={int(d01a,16)>>3&1 if d01a!='??' else '?'} "
                  f"EMMC={int(d01a,16)>>2&1 if d01a!='??' else '?'} "
                  f"EMBC={int(d01a,16)>>1&1 if d01a!='??' else '?'} "
                  f"ERST={int(d01a,16)&1 if d01a!='??' else '?'}")
            print(f"  -> Sprites enabled (D015): {d015}  Collision regs D01E/D01F: {d01e}/{d01f}")

    finally:
        if sock is not None:
            try:
                sock.sendall(b"quit\n")
            except OSError:
                pass
            sock.close()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    return 0


if __name__ == "__main__":
    sys.exit(main())
