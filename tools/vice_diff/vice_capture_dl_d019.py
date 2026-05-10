"""Capture VICE xscpu64 $D019/$D01A/$D012 access trace for Dragon's Lair.

Goal: oracle reference for what DL's IRQ handler ACTUALLY does on a
known-good SuperCPU emulator. Compare against MiSTer SCPU v234 captures
which show RD=$F7 (extra sprite-collision IRQs) vs T65 RD=$F1.

Method:
  - Launch xscpu64 with REU image dl00.reu mounted, -remotemonitor on TCP.
  - Load dlair64ld.prg via `l` monitor command.
  - Resume via `g $0801` (BASIC PRG entry).
  - Run unmonitored for some seconds in warp so DL loads and reaches
    gameplay. (DL phase: SCPU kickstart -> long REU FETCH chain ->
    decompress to bank $00 -> game loop with FLI raster.)
  - After settling delay, break, install trace points on
    load $D019, store $D019, store $D01A, store $D012.
  - Resume `g`, capture trace events for `--capture-secs` seconds.
  - Output: vice_dl_d019_trace.txt with lines:
        <kind> <addr> <pc> <data>
    where kind is L|S, addr is hex, pc is hex (the PC that issued the
    access), data is the byte read or written.
"""

from __future__ import annotations

import argparse
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

VICE_EXE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
DEFAULT_PRG = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
DEFAULT_REU = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
DEFAULT_OUT = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_d019_trace.txt"
DEFAULT_PORT = 6510

PROMPT = b"(C:$"

# Trace event line examples (VICE 3.9):
#   #1 (Trace load d019)  013   .C:ea31  AD 19 D0    LDA $D019      A:F1 ...
#   #2 (Trace store d019) 014   .C:ea34  8D 19 D0    STA $D019      ...
TRACE_LINE_RE = re.compile(
    r"#\d+\s+\(Trace\s+(?P<kind>load|store)\s+(?P<addr>[0-9A-Fa-f]+)\)"
    r".*?\.[CR]:(?P<pc>[0-9A-Fa-f]{4})\s+(?P<bytes>[0-9A-Fa-f ]+?)\s+"
    r"(?P<mnem>[A-Z]{3})\s+",
    re.IGNORECASE,
)
# Fallback: just kind+addr+pc; we infer data from the disasm bytes.
TRACE_KIND_RE = re.compile(
    r"#\d+\s+\(Trace\s+(?P<kind>load|store)\s+(?P<addr>[0-9A-Fa-f]+)\)",
    re.IGNORECASE,
)
DISASM_PC_RE = re.compile(
    r"\.[CR]:(?P<pc>[0-9A-Fa-f]{4})"
)
A_REG_RE = re.compile(r"\bA:(?P<a>[0-9A-Fa-f]{2})")


def expect_prompt(sock: socket.socket, timeout: float = 10.0) -> bytes:
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


def send(sock: socket.socket, line: str, *, drain_secs: float = 0.5) -> str:
    sock.sendall((line.rstrip() + "\n").encode())
    return expect_prompt(sock, timeout=drain_secs + 5).decode(errors="replace")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prg", default=DEFAULT_PRG)
    ap.add_argument("--reu", default=DEFAULT_REU)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--settle-secs", type=float, default=20.0,
                    help="seconds to run unmonitored before installing tracepoints")
    ap.add_argument("--capture-secs", type=float, default=15.0,
                    help="seconds to capture trace events")
    ap.add_argument("--max-events", type=int, default=200_000)
    args = ap.parse_args()

    if not Path(VICE_EXE).exists():
        print(f"error: VICE not found: {VICE_EXE}", file=sys.stderr)
        return 2
    if not Path(args.prg).exists():
        print(f"error: PRG not found: {args.prg}", file=sys.stderr)
        return 2
    if not Path(args.reu).exists():
        print(f"error: REU not found: {args.reu}", file=sys.stderr)
        return 2

    vice_args = [
        VICE_EXE,
        "-autostart", args.prg,
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{args.port}",
        "-reu",
        "-reusize", "16384",
        "-reuimage", args.reu,
        # +reuimagerw -> read-only image. We don't want DL to mutate it.
        "+reuimagerw",
        "-warp",
        "-silent",
    ]
    print(f"[launch] {' '.join(vice_args)}")
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
            print("error: could not connect to VICE monitor", file=sys.stderr)
            return 2
        print(f"[ok] connected on 127.0.0.1:{args.port}")

        expect_prompt(sock, timeout=10.0)

        # -autostart pauses VICE on monitor connect AT the BASIC ready
        # prompt (or possibly inside the autoload sequence). Resume
        # immediately; VICE's autostart will inject the LOAD"*",8,1 +
        # RUN keystrokes which fires the BASIC stub at $080D, which
        # SYSes into the loader.
        sock.sendall(b"x\n")  # x = exit monitor & continue
        print(f"[run] autostart resumed, settling for {args.settle_secs}s "
              f"(warp on, ~80x real time)...")
        time.sleep(args.settle_secs)
        # Re-enter monitor by sending any input over the still-open TCP.
        sock.sendall(b"\n")

        # VICE remote monitor doesn't do Ctrl+C; send a 'reset cycle'
        # equivalent isn't right either. The trick: connect a fresh
        # control sequence — the right way is to use the `g` command's
        # UNIX-style break: send any command line; VICE breaks if it
        # detects monitor input. In remotemonitor mode any input line
        # while running breaks immediately.
        sock.sendall(b"\n")  # any input pauses
        # Drain the disasm dump that VICE prints on break.
        expect_prompt(sock, timeout=5.0)
        print("[ok] paused")

        # Install non-breaking tracepoints. VICE's `tr` (trace) is the
        # non-breaking form of watch — fires a message each access.
        for cmd in [
            "tr load $d019",
            "tr store $d019",
            "tr store $d01a",
            "tr store $d012",
        ]:
            out = send(sock, cmd, drain_secs=1.0)
            print(f"[trace] {cmd}: {out.strip().splitlines()[0] if out.strip() else '(no reply)'}")

        # Resume and capture
        out_path = Path(args.out)
        events = 0
        sock.sendall(b"g\n")
        sock.settimeout(2.0)
        end = time.time() + args.capture_secs
        carry = b""

        raw_log = out_path.with_suffix(".raw.log")
        with out_path.open("w", encoding="utf-8") as fh, raw_log.open("wb") as rf:
            fh.write("# vice_dl_d019_trace v1\n")
            fh.write("# kind addr pc data_or_A_reg\n")
            while time.time() < end and events < args.max_events:
                try:
                    chunk = sock.recv(262144)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                rf.write(chunk)
                rf.flush()
                buf = carry + chunk
                lines = buf.split(b"\n")
                carry = lines[-1]
                for raw in lines[:-1]:
                    line = raw.decode(errors="replace").rstrip()
                    m_full = TRACE_LINE_RE.search(line)
                    if m_full:
                        m_a = A_REG_RE.search(line)
                        a_val = m_a["a"] if m_a else "??"
                        fh.write(f"{m_full['kind'][0].upper()} "
                                 f"{m_full['addr'].lower()} "
                                 f"{m_full['pc'].lower()} "
                                 f"{a_val}\n")
                        events += 1
                        continue
                    m_kind = TRACE_KIND_RE.search(line)
                    if m_kind:
                        m_pc = DISASM_PC_RE.search(line)
                        m_a = A_REG_RE.search(line)
                        pc_val = m_pc["pc"] if m_pc else "????"
                        a_val = m_a["a"] if m_a else "??"
                        fh.write(f"{m_kind['kind'][0].upper()} "
                                 f"{m_kind['addr'].lower()} "
                                 f"{pc_val.lower()} "
                                 f"{a_val}\n")
                        events += 1

        # Drain any dangling output then quit.
        time.sleep(0.5)
        try:
            sock.sendall(b"x\n")  # exit monitor (continue)
        except OSError:
            pass
        print(f"[done] wrote {events} events to {out_path}")

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
