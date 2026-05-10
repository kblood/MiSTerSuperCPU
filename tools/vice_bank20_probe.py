"""Verify `bank ram20` selects SuperRAM bank $20 for subsequent `>`/`m` commands."""
import socket, subprocess, time

VICE_EXE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"

def main():
    p = subprocess.Popen([
        VICE_EXE, "-remotemonitor", "-remotemonitoraddress", "127.0.0.1:6510", "-warp"
    ], creationflags=subprocess.DETACHED_PROCESS)
    time.sleep(2.0)

    s = socket.socket(); s.connect(("127.0.0.1", 6510)); s.settimeout(0.5)

    def drain(t=1.0):
        buf = b""; end = time.time() + t
        while time.time() < end:
            try: buf += s.recv(65536)
            except socket.timeout: break
        return buf.decode(errors="replace")

    def cmd(c):
        s.sendall((c + "\r\n").encode()); time.sleep(0.3)
        return drain(0.5).encode("ascii", "replace").decode("ascii")

    drain(2.0); cmd("reset 0"); drain(1.0)

    print("--- bank ram20 + poke + read ---")
    print(cmd("bank ram20"))
    print(cmd("> $0000 de ad be ef ca fe ba be"))
    print(cmd("m $0000 $000f"))

    # Switch back to cpu, check it's separate
    print("--- bank cpu (default) — should NOT see DE AD ---")
    print(cmd("bank cpu"))
    print(cmd("m $0000 $000f"))

    # Verify bank ram20 sticks
    print("--- bank ram20 again, verify same bytes ---")
    print(cmd("bank ram20"))
    print(cmd("m $0000 $000f"))

    cmd("quit"); s.close(); time.sleep(0.3); p.kill()

if __name__ == "__main__":
    main()
