"""Probe what VICE's remote text monitor actually emits.

Just connect and dump everything for a fixed time window so we can figure
out the prompt format and the chis output shape before writing the real
capture script.
"""
import socket, subprocess, time, sys
from pathlib import Path

VICE_EXE = r"D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
PRG = r"C:\LLM\C64\MiSTerSuperCPU\asterix.prg"

proc = subprocess.Popen([
    VICE_EXE,
    "-autostart", PRG,
    "-remotemonitor",
    "-remotemonitoraddress", "127.0.0.1:6510",
    "-monchislines", "10000",
    "-silent",
])

# Connect
sock = None
for _ in range(20):
    try:
        sock = socket.create_connection(("127.0.0.1", 6510), timeout=2.0)
        break
    except Exception:
        time.sleep(0.5)
assert sock, "could not connect"
print("[ok] connected")

def drain(t=2.0):
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

# Banner
b = drain(3.0)
print("=== BANNER ===")
print(repr(b[-500:]))

# Try sending a register query
sock.sendall(b"r\n")
time.sleep(1.0)
r = drain(2.0)
print("=== r RESPONSE ===")
print(repr(r))

# Try setting a breakpoint
sock.sendall(b"break $cb00\n")
time.sleep(0.5)
b2 = drain(2.0)
print("=== break $cb00 RESPONSE ===")
print(repr(b2))

# Try `bk` shortcut
sock.sendall(b"bk\n")
time.sleep(0.5)
b3 = drain(2.0)
print("=== bk RESPONSE ===")
print(repr(b3))

# Continue
sock.sendall(b"g\n")
print("[ok] sent g, sleeping 30s for breakpoint to fire")
time.sleep(30)
g = drain(5.0)
print("=== g RESPONSE (after 30s) ===")
print(g[-3000:])

# Try chis
sock.sendall(b"chis 50\n")
time.sleep(2.0)
c = drain(5.0)
print("=== chis 50 RESPONSE ===")
print(repr(c[:5000]))

# Try help to see available commands
sock.sendall(b"help\n")
time.sleep(2.0)
h = drain(5.0)
print("=== help RESPONSE ===")
print(h[:8000])

# help on cpuhistory specifically
sock.sendall(b"help cpuhistory\n")
time.sleep(1.0)
print("=== help cpuhistory ===")
print(drain(3.0))

# Step a few instructions, then chis
for _ in range(10):
    sock.sendall(b"z\n")
    time.sleep(0.05)
drain(2.0)
print("=== after 10 steps, chis 20 ===")
sock.sendall(b"chis 20\n")
time.sleep(1.0)
print(repr(drain(3.0)[:5000]))

# Try chis without args
sock.sendall(b"chis\n")
time.sleep(1.0)
print("=== chis no args ===")
print(repr(drain(3.0)[:5000]))

# Try with explicit device
sock.sendall(b"chis 20 c:\n")
time.sleep(1.0)
print("=== chis 20 c: ===")
print(repr(drain(3.0)[:5000]))

# Check resource for chislines
sock.sendall(b"resget MonitorChisLines\n")
time.sleep(1.0)
print("=== resget MonitorChisLines ===")
print(repr(drain(3.0)[:1000]))

# Also list all resources matching chis or hist or history
sock.sendall(b"resget MainCPU_TRACE\n")
time.sleep(0.5)
print("=== resget MainCPU_TRACE ===")
print(repr(drain(2.0)[:500]))

# help on trace
sock.sendall(b"help trace\n")
time.sleep(0.5)
print("=== help trace ===")
print(drain(2.0)[:1500])

# Try trace command (range tracepoint that prints each hit)
sock.sendall(b"trace exec $0000 $ffff\n")
time.sleep(1.0)
print("=== trace exec $0000 $ffff ===")
print(repr(drain(2.0)[:1000]))

# Then step a few and see output
for _ in range(5):
    sock.sendall(b"z\n")
    time.sleep(0.05)
print("=== after 5 steps with trace active ===")
print(drain(3.0)[:2000])

# Disable that trace, try a small range
sock.sendall(b"del 2\n")  # delete tracepoint #2
time.sleep(0.5)
drain(1.0)

# Try a watch instead
sock.sendall(b"watch $cb00 $cb20\n")
time.sleep(0.5)
print("=== watch $cb00 $cb20 ===")
print(repr(drain(2.0)[:500]))

# Quit
sock.sendall(b"quit\n")
time.sleep(1.0)
sock.close()
proc.terminate()
try:
    proc.wait(timeout=5)
except Exception:
    proc.kill()
