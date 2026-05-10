"""Try to bypass DL's $3093 IRQ-wait loop on VICE xscpu64 by poking $45=$01.

Hypothesis: VICE doesn't fire the IRQ that DL's loader expects to set
zero-page $45 (likely a CIA1 or VIC source-enable mismatch). If we
manually poke $45=$01 from the monitor while broken at $3093, DL may
fall through `BEQ $309B` -> `JMP $8F2B` and reach actual gameplay.

If post-bypass DL renders correctly, VICE becomes a viable oracle for
the rendering bug (we just step around the boot-time IRQ divergence).

Method:
  1. Launch xscpu64 with autostart + REU image, warp, silent.
  2. Settle 60s.
  3. Break, confirm PC near $3093.
  4. Set $45=$01 via monitor write.
  5. Continue, give 30s to render.
  6. Break again, dump PC/VIC state. If PC is now in $9F13/$8F2B/etc.
     and $D018/$DD00 match MiSTer's gameplay-time values, oracle lives.
"""
import argparse
import socket
import subprocess
import sys
import time
from pathlib import Path

VICE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
PRG = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
REU = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
OUT = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_bypass_45.log"
PORT = 6510


def drain(sock, idle=0.4, max_wait=5.0):
    sock.settimeout(idle)
    buf = b""
    end = time.time() + max_wait
    while time.time() < end:
        try:
            c = sock.recv(65536)
            if not c:
                break
            buf += c
        except socket.timeout:
            break
    return buf.decode(errors="replace")


def cmd(sock, line, max_wait=4.0):
    drain(sock, 0.05, 0.2)
    sock.sendall((line + "\n").encode())
    return drain(sock, 0.4, max_wait)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settle", type=float, default=60.0)
    ap.add_argument("--post-bypass", type=float, default=30.0)
    args = ap.parse_args()

    vargs = [VICE, "-autostart", PRG, "-remotemonitor",
             "-remotemonitoraddress", f"127.0.0.1:{PORT}",
             "-reu", "-reusize", "16384", "-reuimage", REU,
             "+reuimagerw", "-warp", "-silent"]
    proc = subprocess.Popen(vargs)
    sock = None
    log_lines = []

    def log(s):
        try:
            print(s)
        except UnicodeEncodeError:
            print(s.encode("ascii", "replace").decode("ascii"))
        log_lines.append(s)

    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", PORT), timeout=2)
                break
            except OSError:
                time.sleep(0.5)
        if sock is None:
            log("error: monitor connect failed")
            return 2
        drain(sock, 0.3, 5.0)

        # Run autostart, settle
        sock.sendall(b"x\n")
        log(f"[run] settling {args.settle}s warp...")
        time.sleep(args.settle)

        # Break + check PC
        sock.sendall(b"\n")
        drain(sock, 0.3, 3.0)
        out_r = cmd(sock, "r", max_wait=3.0)
        log("\n=== Pre-bypass register dump ===")
        log(out_r.strip())

        # Read $45 to confirm it's $00 (the wait gate)
        out_45 = cmd(sock, "m $0045 $0045", max_wait=2.0)
        log("\n=== Pre-bypass $45 ===")
        log(out_45.strip())

        # Poke $45 = $00 to satisfy BEQ $309B (loop exits when $45 == 0).
        # Pre-bypass $45=$FF was the *blocker* — DL waits for an IRQ to
        # zero it. VICE's $D01A=$F0 = no IRQ enabled, so the IRQ never
        # fires. Forcing $45=$00 should let DL fall through to $8F2B.
        log("\n=== Bypass: writing $45 = $00 ===")
        out_w = cmd(sock, "> $45 00", max_wait=2.0)
        log(out_w.strip())

        # Confirm write
        out_45b = cmd(sock, "m $0045 $0045", max_wait=2.0)
        log("\n=== Post-poke $45 ===")
        log(out_45b.strip())

        # Continue, give time to advance
        sock.sendall(b"x\n")
        log(f"[run] post-bypass {args.post_bypass}s warp...")
        time.sleep(args.post_bypass)

        # Break + new register/VIC dump
        sock.sendall(b"\n")
        drain(sock, 0.3, 3.0)
        out_r2 = cmd(sock, "r", max_wait=3.0)
        log("\n=== Post-bypass register dump ===")
        log(out_r2.strip())

        out_vic = cmd(sock, "m $d000 $d02f", max_wait=3.0)
        log("\n=== Post-bypass VIC ($D000-$D02F) ===")
        log(out_vic.strip())

        out_cia2 = cmd(sock, "m $dd00 $dd0f", max_wait=3.0)
        log("\n=== Post-bypass CIA2 ===")
        log(out_cia2.strip())

        # Sample a few times to confirm PC moves
        log("\n=== PC sampling (3x with continue between) ===")
        for i in range(3):
            sock.sendall(b"x\n")
            time.sleep(2.0)
            sock.sendall(b"\n")
            drain(sock, 0.2, 2.0)
            out_ri = cmd(sock, "r", max_wait=2.0)
            log(f"--- sample {i+1} ---")
            log(out_ri.strip())

        # Save log
        Path(OUT).write_text("\n".join(log_lines), encoding="utf-8")
        log(f"\n[done] -> {OUT}")
        return 0
    finally:
        if sock:
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


if __name__ == "__main__":
    sys.exit(main())
