#!/usr/bin/env python3
"""vice_scpu_regprobe.py — capture SCPU status-register ground truth from VICE xscpu64.

Autostarts tools/scpu_regprobe.prg in xscpu64 (the canonical SuperCPU emulator),
lets it run, then dumps scratch RAM $C000..$C009 via the remote text monitor.
These are the values a real SuperCPU returns for the detection/status registers —
the differential oracle for our FPGA read-mux.
"""
import socket, subprocess, time, sys, os, re

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
PRG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scpu_regprobe.prg")
PORT = 6512

REGS = ["D0B0", "D0B2", "D0B3", "D0B4", "D0B5", "D0B6", "D0B8", "D0BC", "D07E", "D078"]


def drain(sock, t=2.0):
    sock.settimeout(t)
    out = b""
    try:
        while True:
            c = sock.recv(65536)
            if not c:
                break
            out += c
    except socket.timeout:
        pass
    return out.decode(errors="replace")


def main():
    if not os.path.exists(VICE_EXE):
        print(f"VICE not found at {VICE_EXE}")
        return 2
    proc = subprocess.Popen([
        VICE_EXE,
        "-autostart", PRG,
        "-remotemonitor",
        "-remotemonitoraddress", f"127.0.0.1:{PORT}",
        "-warp", "-silent",
    ])
    try:
        sock = None
        for _ in range(40):
            try:
                sock = socket.create_connection(("127.0.0.1", PORT), timeout=2.0)
                break
            except Exception:
                time.sleep(0.5)
        if not sock:
            print("could not connect to VICE monitor")
            return 3
        drain(sock, 2.0)
        # let the PRG autoload + run (warp); a few real seconds is plenty
        print("Letting probe run in warp...")
        time.sleep(6)
        # The monitor connection pauses emulation when it receives input; send
        # an explicit 'g' first to make sure it ran, wait, then break and dump.
        sock.sendall(b"g\n")
        time.sleep(3)
        # dump scratch
        sock.sendall(b"m c000 c00f\n")
        time.sleep(1.0)
        resp = drain(sock, 3.0)
        print("=== raw monitor dump ===")
        print(resp)
        # parse the memory line(s): VICE format ">C:c000  40 80 00 ..  ...."
        vals = {}
        for line in resp.splitlines():
            m = re.search(r"[>\.]?\s*C?:?c000\b(.*)", line, re.IGNORECASE)
            if "c000" in line.lower():
                hexbytes = re.findall(r"\b([0-9a-fA-F]{2})\b", line.split("c000", 1)[1])
                if len(hexbytes) >= 10:
                    for i, name in enumerate(REGS):
                        vals[name] = hexbytes[i].upper()
                    break
        if vals:
            print("\n=== VICE xscpu64 GROUND TRUTH ===")
            for name in REGS:
                print(f"  ${name} = ${vals.get(name,'??')}")
        else:
            print("Could not parse; inspect raw dump above.")
        sock.sendall(b"quit\n")
        time.sleep(0.5)
        sock.close()
    finally:
        try:
            proc.terminate(); proc.wait(timeout=5)
        except Exception:
            proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
