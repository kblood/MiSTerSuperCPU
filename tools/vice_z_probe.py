"""Probe what VICE's `z` command prints. If it prints regs after step,
we can halve stepwise capture RTT by skipping the separate `r` call."""
import socket, subprocess, time, sys

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"

def main():
    p = subprocess.Popen([
        VICE_EXE, "-remotemonitor", "-remotemonitoraddress", "127.0.0.1:6510",
        "-warp", "-silent",
    ], creationflags=subprocess.DETACHED_PROCESS)
    time.sleep(2.0)

    s = socket.socket(); s.connect(("127.0.0.1", 6510)); s.settimeout(0.5)

    def drain(t=1.0):
        buf = b""; end = time.time() + t
        while time.time() < end:
            try: buf += s.recv(65536)
            except socket.timeout: break
        return buf.decode(errors="replace")

    def cmd(c, w=0.4):
        s.sendall((c + "\r\n").encode()); time.sleep(0.1)
        return drain(w).encode("ascii", "replace").decode("ascii")

    drain(2.0); cmd("reset 0"); drain(1.0)

    # Park at $0800 with a known program
    print("=== load + bp ===")
    print(cmd("> $0800 78 ea ea ea"))
    print(cmd("break $0800"))
    print(cmd("g $0800", w=2.0))

    # Now try z and see what comes back
    print("=== z (step #1) ===")
    print(repr(cmd("z")))
    print("=== z (step #2) ===")
    print(repr(cmd("z")))
    print("=== r (separate) ===")
    print(repr(cmd("r")))

    cmd("quit"); s.close(); time.sleep(0.3); p.kill()

if __name__ == "__main__":
    main()
