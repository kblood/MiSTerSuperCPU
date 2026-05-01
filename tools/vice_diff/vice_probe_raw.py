"""Diagnostic: launch x64sc, settle, then dump raw monitor output for a few sample cycles."""
import socket, subprocess, sys, time
from pathlib import Path

VICE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\x64sc.exe"
PRG  = r"C:\LLM\C64\MiSTerSuperCPU\tools\dlair64ld.prg"
REU  = r"C:\LLM\C64\MiSTerSuperCPU\dlair_assets\dl00.reu"
PORT = 6510

vice_args = [
    VICE,
    "-autostart", PRG,
    "-remotemonitor",
    "-remotemonitoraddress", f"127.0.0.1:{PORT}",
    "-reu",
    "-reusize", "16384",
    "-reuimage", REU,
    "+reuimagerw",
    "-warp",
    "-silent",
]
proc = subprocess.Popen(vice_args)
sock = None
try:
    end = time.time() + 15
    while time.time() < end:
        try:
            sock = socket.create_connection(("127.0.0.1", PORT), timeout=2.0)
            break
        except OSError:
            time.sleep(0.5)
    sock.settimeout(2.0)

    print("=== INITIAL CONNECT ===")
    buf = b""
    deadline = time.time() + 3
    while time.time() < deadline:
        try:
            buf += sock.recv(8192)
        except socket.timeout:
            break
    print(repr(buf[-500:]))

    sock.sendall(b"x\n")
    print("\n=== AFTER x (resume) — sleeping 20s ===")
    time.sleep(20)

    for i in range(5):
        sock.sendall(b"\n")
        time.sleep(0.1)
        buf = b""
        deadline = time.time() + 1.0
        while time.time() < deadline:
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
            except socket.timeout:
                break
        print(f"\n=== SAMPLE {i}: response after blank-line interrupt ===")
        print(repr(buf[:1500]))
        sock.sendall(b"g\n")
        time.sleep(0.05)
finally:
    if sock: sock.close()
    proc.terminate()
