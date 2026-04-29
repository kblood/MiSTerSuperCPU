"""Variant of vice_capture_chis.py: pre-fill $C000-$FEFF with $FF before
running asterix. Tests the hypothesis that hardware's C003 hang is caused
by uninitialised RAM in $C0xx range — if VICE also hangs with $FF fill,
the hypothesis is confirmed in oracle.
"""
from __future__ import annotations

import argparse, re, socket, subprocess, sys, time
from pathlib import Path

VICE_EXE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
DEFAULT_PRG  = r"C:\LLM\C64\MiSTerSuperCPU\asterix.prg"
PROMPT = b"(C:$"

DISASM_RE = re.compile(r"^\s*\.[CR]:(?P<pc>[0-9A-Fa-f]{4})\s+(?P<ir>[0-9A-Fa-f]{2})")
TRACE_EXEC_RE = re.compile(r"#\d+\s+\(Trace\s+exec\s+(?P<pc>[0-9A-Fa-f]{4})\)")


def drain(sock, deadline_s, idle_s=0.3):
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
    sock.settimeout(timeout)
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk: break
        buf += chunk
        if PROMPT in buf:
            return buf
    return buf


def cmd(sock, line, timeout=10.0):
    sock.sendall((line.rstrip() + "\n").encode())
    return expect_prompt(sock, timeout=timeout).decode(errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prg", default=DEFAULT_PRG)
    ap.add_argument("--out", default=r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_garbage_trace.txt")
    ap.add_argument("--port", type=int, default=6510)
    ap.add_argument("--max-instr", type=int, default=20000)
    ap.add_argument("--start-pc", default="0820")  # phase-1 entry; we don't break-then-trace, just JMP-and-trace
    ap.add_argument("--stop-pc", default="cb00")
    ap.add_argument("--trace-timeout", type=float, default=120.0)
    ap.add_argument("--garbage-byte", default="ff", help="byte to fill $C000-$FEFF with")
    args = ap.parse_args()

    proc = subprocess.Popen([
        VICE_EXE, "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{args.port}",
        "-silent", "-warp",
    ])

    sock = None
    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", args.port), timeout=2.0); break
            except OSError: time.sleep(0.5)
        if sock is None:
            print("error: no VICE connection", file=sys.stderr); return 2
        expect_prompt(sock, 10.0)

        # Load PRG
        prg = args.prg.replace("\\", "/")
        out = cmd(sock, f'l "{prg}" 0', 10.0)
        print(f"[load] {out.strip()[:200]}")

        # Fill $C000-$FEFF with garbage byte
        out = cmd(sock, f"f $c000 $feff ${args.garbage_byte}", 5.0)
        print(f"[fill] {out.strip()[:200]}")

        # Verify a few bytes
        out = cmd(sock, f"m $c003 $c00f", 3.0)
        print(f"[verify $C003-$C00F] {out.strip()[:300]}")

        # Set break + JMP to phase-1 entry
        cmd(sock, f"break ${args.start_pc}", 5.0)
        sock.sendall(b"g\n"); sock.settimeout(2.0)
        # Wait for start_pc hit
        hit_buf = b""; end = time.time() + 60
        while time.time() < end:
            try: chunk = sock.recv(65536)
            except socket.timeout: continue
            if not chunk: break
            hit_buf += chunk
            if f"Stop on  exec {args.start_pc}".encode() in hit_buf:
                break
        expect_prompt(sock, 2.0)
        cmd(sock, "del 1", 3.0)  # remove start BP

        cmd(sock, f"trace exec $0000 $ffff", 5.0)
        cmd(sock, f"break ${args.stop_pc}", 5.0)
        # Add safety BP on $C003 directly (so we can confirm landing)
        cmd(sock, f"break $c003", 5.0)
        drain(sock, 0.3)

        # Resume
        sock.sendall(b"g\n"); sock.settimeout(2.0)
        end = time.time() + args.trace_timeout
        carry = b""; seq = 0; last_pc = None
        c003_seen = False; cb00_seen = False
        out_path = Path(args.out)
        with out_path.open("w") as fh:
            fh.write("TRACE_START\n")
            while time.time() < end and seq < args.max_instr:
                try: chunk = sock.recv(262144)
                except socket.timeout: continue
                if not chunk: break
                buf = carry + chunk
                lines = buf.split(b"\n"); carry = lines[-1]
                for raw in lines[:-1]:
                    line = raw.decode(errors="replace").rstrip()
                    m = TRACE_EXEC_RE.search(line)
                    if m:
                        last_pc = int(m["pc"], 16); continue
                    md = DISASM_RE.match(line)
                    if md and last_pc is not None:
                        pc = int(md["pc"], 16)
                        if pc == last_pc:
                            ir = int(md["ir"], 16)
                            fh.write(f"{seq}:00:{pc:04x}:{ir:02x}:00:0000\n")
                            seq += 1
                            last_pc = None
                if b"(Stop on  exec c003)" in buf.lower():
                    c003_seen = True
                    print(f"[!] $c003 hit at seq {seq}")
                    end = 0; break
                if b"(Stop on  exec cb00)" in buf.lower():
                    cb00_seen = True
                    print(f"[!] $cb00 hit at seq {seq}")
                    end = 0; break
        print(f"[done] wrote {seq} trace lines to {out_path}")
        print(f"  c003_seen: {c003_seen}, cb00_seen: {cb00_seen}")

    finally:
        if sock:
            try: sock.sendall(b"quit\n")
            except OSError: pass
            sock.close()
        if proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
