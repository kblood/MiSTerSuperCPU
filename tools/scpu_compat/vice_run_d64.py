#!/usr/bin/env python3
"""Differential oracle: run a .d64 in VICE xscpu64 and capture a screenshot.

Autostarts the disk's first file in the canonical SuperCPU emulator, lets it
run a few seconds (real-time, NOT warp, so timed effects settle), then grabs a
VIC-II screenshot via the remote text monitor. The reference for what disk 1
of an SCPU title SHOULD look like, to disambiguate "our-core bug" vs
"demo-is-fragile" per the project's differential-oracle methodology.

Usage: python tools/scpu_compat/vice_run_d64.py <local.d64> [out.png] [run_secs]
"""
import socket, subprocess, time, sys, os

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
PORT = 6512


def drain(sock, t=1.5):
    sock.settimeout(t); out = b""
    try:
        while True:
            c = sock.recv(65536)
            if not c: break
            out += c
    except socket.timeout:
        pass
    return out.decode(errors="replace")


def main():
    d64 = sys.argv[1]
    out_png = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(d64)[0] + "_vice.png"
    run_secs = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    out_png = os.path.abspath(out_png)
    if not os.path.exists(VICE_EXE):
        print("VICE not found"); return 2
    proc = subprocess.Popen([
        VICE_EXE, "-autostart", os.path.abspath(d64),
        "-remotemonitor", "-remotemonitoraddress", f"127.0.0.1:{PORT}",
        "-silent",
    ])
    try:
        sock = None
        for _ in range(40):
            try:
                sock = socket.create_connection(("127.0.0.1", PORT), timeout=2.0); break
            except Exception:
                time.sleep(0.5)
        if not sock:
            print("no monitor connection"); return 3
        drain(sock, 1.5)
        sock.sendall(b"g\n")           # ensure running
        print(f"running {run_secs}s real-time ...")
        time.sleep(run_secs)
        # screenshot pauses emulation on monitor input; capture current frame.
        # VICE monitor wants forward slashes; pass explicit PNG format arg.
        fwd = out_png.replace("\\", "/")
        sock.sendall(f'screenshot "{fwd}" 2\n'.encode())
        time.sleep(1.5)
        print("monitor resp:", repr(drain(sock, 2.0)))
        sock.sendall(b"g\n"); time.sleep(0.3)
        sock.sendall(b"quit\n"); time.sleep(0.4); sock.close()
    finally:
        try:
            proc.terminate(); proc.wait(timeout=5)
        except Exception:
            proc.kill()
    print("screenshot ->", out_png, "exists" if os.path.exists(out_png) else "MISSING")
    return 0


if __name__ == "__main__":
    sys.exit(main())
