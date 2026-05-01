"""Capture PC samples from VICE x64sc running Dragon's Lair (vanilla C64
mode = T65 equivalent).

Goal: oracle reference for "what does correct DL look like at PC level".
Hardware T65 capture (tools/dl_uart_t65_*.txt) shows a perfect 5-frame
PC cycle at vblank pages $30/$80/$83/$85/$89. If x64sc reproduces this
same cycle, our hardware T65 sampler is faithful.

Method: poll-interrupt sampler. VICE's remote monitor breaks on any
input. We send blank lines at intervals, parse the PC from the disasm
prompt, send `g` to continue, repeat. Loose timing is fine — we want
the page DISTRIBUTION not vblank-precise sampling.

Per CLAUDE.md memory project_vice_xscpu64_blocks_dl_oracle: xscpu64
hangs DL at $3093 — this script intentionally runs x64sc only.
"""

from __future__ import annotations

import argparse
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

VICE_X64SC_EXE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\x64sc.exe"
DEFAULT_PRG = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
DEFAULT_REU = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
DEFAULT_OUT = r"C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_dl_x64sc_pc.txt"
DEFAULT_PORT = 6510

PROMPT = b"(C:$"
# VICE break prompt format: "(C:$8b3b) "
DISASM_PC_RE = re.compile(r"\(C:\$(?P<pc>[0-9A-Fa-f]{4})\)")


def expect_prompt(sock: socket.socket, timeout: float = 5.0) -> bytes:
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prg", default=DEFAULT_PRG)
    ap.add_argument("--reu", default=DEFAULT_REU)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--vice-exe", default=VICE_X64SC_EXE)
    ap.add_argument("--settle-secs", type=float, default=20.0)
    ap.add_argument("--samples", type=int, default=500)
    ap.add_argument("--no-warp", action="store_true",
                    help="Run without -warp (slower but maybe clearer for stepping)")
    args = ap.parse_args()

    if not Path(args.vice_exe).exists():
        print(f"error: VICE not found: {args.vice_exe}", file=sys.stderr)
        return 2

    vice_args = [
        args.vice_exe,
        "-autostart", args.prg,
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{args.port}",
        "-reu",
        "-reusize", "16384",
        "-reuimage", args.reu,
        "+reuimagerw",
        "-silent",
    ]
    if not args.no_warp:
        vice_args.insert(-1, "-warp")
    print(f"[launch] {args.vice_exe} (x64sc)")
    proc = subprocess.Popen(vice_args)

    sock = None
    pcs = []
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
        sock.sendall(b"x\n")  # resume autostart
        print(f"[run] settling {args.settle_secs}s...")
        time.sleep(args.settle_secs)

        for i in range(args.samples):
            # interrupt
            sock.sendall(b"\n")
            blob = expect_prompt(sock, timeout=2.0).decode(errors="replace")
            m = DISASM_PC_RE.search(blob)
            if m:
                pcs.append(m["pc"].lower())
            else:
                pcs.append("????")
            sock.sendall(b"g\n")
            # let CPU run for a frame-ish (50fps -> 20ms) ; warp shrinks this
            time.sleep(0.02)

        out_path = Path(args.out)
        with out_path.open("w", encoding="utf-8") as fh:
            fh.write("# vice_dl_x64sc_pc v2 (poll-interrupt)\n")
            fh.write("# N PC\n")
            for i, pc in enumerate(pcs):
                fh.write(f"{i} {pc}\n")
        print(f"[done] wrote {len(pcs)} samples to {out_path}")
        # quick page histogram
        from collections import Counter
        pages = Counter(pc[:2] if len(pc) == 4 else "??" for pc in pcs)
        print("[pages] top 10:")
        for p, c in pages.most_common(10):
            print(f"   ${p}xx  {c:5d}  ({100*c/len(pcs):5.1f}%)")

    finally:
        if sock is not None:
            try: sock.close()
            except OSError: pass
        try:
            proc.terminate()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
