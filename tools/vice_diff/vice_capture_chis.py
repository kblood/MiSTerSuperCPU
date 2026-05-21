"""Capture a VICE xscpu64 PC trace via the text remote-monitor.

Method (validated 2026-04-25):
  - Launch xscpu64 with -remotemonitor on TCP, autostart asterix.prg.
  - Set break at $0852 (phase-2 entry) so we skip phase-1's deterministic
    relocator (~6M instructions of memcpy that the diff doesn't care about).
  - On break, install `trace exec $0000-$ffff` and break at $CB00.
  - Continue. VICE emits per-instruction event+disasm lines that we
    stream-parse into trace_format.md format.

Output: tools/vice_diff/vice_trace.txt with lines:
    <seq>:<pbr>:<pc>:<ir>:<p>:<sp>

P and SP are placeholder $00/$0000 — VICE's `trace` doesn't include them
per-instruction. PC+IR alone is enough to find the first divergence.
"""

from __future__ import annotations

import argparse
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

VICE_EXE  = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
DEFAULT_PRG  = r"C:\LLM\C64\MiSTerSuperCPU\asterix.prg"
DEFAULT_PORT = 6510

# `.C:cb19  8D 22 D0    STA $D022  119238978`
DISASM_RE = re.compile(
    r"^\s*\.[CR]:(?P<pc>[0-9A-Fa-f]{4})\s+"
    r"(?P<ir>[0-9A-Fa-f]{2})"
)
# `#2 (Trace  exec cb19)   ...`
TRACE_EXEC_RE = re.compile(r"#\d+\s+\(Trace\s+exec\s+(?P<pc>[0-9A-Fa-f]{4})\)")

PROMPT = b"(C:$"


def drain(sock, deadline_s, idle_s=0.3):
    """Read from sock until idle for idle_s, or absolute deadline_s."""
    sock.settimeout(idle_s)
    buf = b""
    end = time.time() + deadline_s
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf


def expect_prompt(sock, timeout=10.0):
    """Read until we see a monitor prompt."""
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


def cmd(sock, line, wait_prompt=True, timeout=10.0):
    sock.sendall((line.rstrip() + "\n").encode())
    if wait_prompt:
        return expect_prompt(sock, timeout=timeout).decode(errors="replace")
    return ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prg", default=DEFAULT_PRG)
    ap.add_argument("--out", default=r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_trace.txt")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--start-pc", default="0852",
                    help="hex PC to begin tracing at (default 0852 = phase-2 entry)")
    ap.add_argument("--stop-pc", default="cb00",
                    help="hex PC to stop tracing at (default cb00 = decompressor exit)")
    ap.add_argument("--max-instr", type=int, default=600_000,
                    help="hard cap on emitted trace lines (default 600k)")
    ap.add_argument("--launch-timeout", type=float, default=15.0)
    ap.add_argument("--start-timeout", type=float, default=180.0,
                    help="seconds to wait for start-pc breakpoint to fire")
    ap.add_argument("--trace-timeout", type=float, default=600.0,
                    help="seconds to wait for stop-pc to fire while tracing")
    args = ap.parse_args()

    if not Path(VICE_EXE).exists():
        print(f"error: {VICE_EXE} not found", file=sys.stderr)
        return 2
    if not Path(args.prg).exists():
        print(f"error: PRG not found: {args.prg}", file=sys.stderr)
        return 2

    # NOTE: do NOT pass -autostart. Autostart's keystroke injection is
    # unreliable under monitor pause. Instead we load the PRG manually via
    # `l` (load) command after monitor connects.
    vice_args = [
        VICE_EXE,
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{args.port}",
        "-silent",
        "-warp",
    ]
    print(f"[launch] {' '.join(vice_args)}")
    proc = subprocess.Popen(vice_args)

    sock = None
    try:
        end = time.time() + args.launch_timeout
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

        # VICE pauses on monitor connect at boot ($FFE4 area). Resume to let
        # the autostart sequence complete (LOAD via injected RAM image, then
        # RUN via keybuf). We then break at $0820 (phase-1 entry) to catch
        # asterix's PRG entry exactly. We do this BEFORE setting trace.
        # Load PRG into RAM directly. VICE's `l` command takes filename and
        # device 0 (host filesystem). Quotes around path required.
        prg_for_vice = args.prg.replace("\\", "/")
        load_cmd = f'l "{prg_for_vice}" 0'
        out = cmd(sock, load_cmd, timeout=10.0)
        print(f"[load] {out.strip()[:300]}")

        # Skip $0820 wait — we'll JMP there directly. Just ensure we're
        # at a stable PC and the load succeeded.
        # VICE's `g <addr>` continues execution starting from <addr>.

        # Install start_pc BP and JMP directly to phase-1 entry $0820
        out = cmd(sock, f"break ${args.start_pc}", timeout=10.0)
        print(f"[start-bp] {out.strip()[:200]}")
        # Drain residual
        drain(sock, deadline_s=0.5)

        # `g $0820` continues execution starting at phase-1 entry
        sock.sendall(b"g $0820\n")
        sock.settimeout(2.0)
        hit_buf = b""
        end = time.time() + args.start_timeout
        seen_break = False
        last_report = time.time()
        while time.time() < end:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                if time.time() - last_report > 10:
                    print(f"  ...elapsed={int(time.time()-(end-args.start_timeout))}s buf={len(hit_buf)}B")
                    last_report = time.time()
                continue
            if not chunk:
                break
            hit_buf += chunk
            if (f"Stop on  exec {args.start_pc}".lower().encode() in hit_buf.lower() or
                f"Stop on  exec {args.start_pc.lstrip('0') or '0'}".lower().encode() in hit_buf.lower()):
                seen_break = True
                if PROMPT in hit_buf:
                    break
        if not seen_break:
            tail = hit_buf[-2000:].decode(errors="replace")
            print(f"warn: start breakpoint did not fire in {args.start_timeout}s")
            print(f"      last bytes from VICE: {tail!r}")
            return 3
        print(f"[ok] start_pc ${args.start_pc} reached")
        expect_prompt(sock, timeout=2.0)

        # CRITICAL: delete the start_pc BP so it doesn't re-fire on every
        # phase-2 inner-loop branch back to $0852.
        cmd(sock, "del 1", timeout=5.0)
        print(f"[ok] deleted start BP")

        # Install trace and stop-bp
        cmd(sock, f"trace exec $0000 $ffff", timeout=5.0)
        cmd(sock, f"break ${args.stop_pc}", timeout=5.0)
        print(f"[trace] armed exec $0000-$ffff, stop bp at ${args.stop_pc}")

        # Stream trace events until stop-pc fires, parsing on the fly
        out_path = Path(args.out)
        seq = 0
        last_pc_from_event = None
        sock.sendall(b"g\n")
        sock.settimeout(2.0)
        end = time.time() + args.trace_timeout
        carry = b""

        with out_path.open("w") as fh:
            fh.write("TRACE_START\n")
            while time.time() < end and seq < args.max_instr:
                try:
                    chunk = sock.recv(262144)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf = carry + chunk
                lines = buf.split(b"\n")
                carry = lines[-1]
                for raw in lines[:-1]:
                    line = raw.decode(errors="replace").rstrip()
                    m_evt = TRACE_EXEC_RE.search(line)
                    if m_evt:
                        last_pc_from_event = int(m_evt["pc"], 16)
                        continue
                    m_dis = DISASM_RE.match(line)
                    if m_dis and last_pc_from_event is not None:
                        pc = int(m_dis["pc"], 16)
                        if pc == last_pc_from_event:
                            ir = int(m_dis["ir"], 16)
                            fh.write(f"{seq}:00:{pc:04x}:{ir:02x}:00:0000\n")
                            seq += 1
                            last_pc_from_event = None
                            if seq >= args.max_instr:
                                break
                # Diagnostic: dump first chunk content to a file
                if seq < 50 and len(buf) > 0:
                    import os
                    diag = Path(args.out).with_suffix(".raw_chunks.log")
                    with diag.open("ab") as df:
                        df.write(b"=== chunk ===\n")
                        df.write(buf[:4000])
                        df.write(b"\n")
                # Pragmatic exit when we hit the stop_pc: search for the
                # break-hit message which is `#N (Stop on  exec cb00) ...`.
                # IMPORTANT: don't false-trigger on `BREAK: N  C:$cb00  (Stop on exec)`
                # which is the BP-installation response.
                stop_marker = f"(Stop on  exec {args.stop_pc})".encode().lower()
                if stop_marker in buf.lower():
                    print(f"[ok] stop_pc ${args.stop_pc} reached at seq {seq}")
                    end = 0  # break outer loop too
                    break
            print(f"[done] wrote {seq} trace lines to {out_path}")

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
