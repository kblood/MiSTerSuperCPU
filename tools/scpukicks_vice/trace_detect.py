#!/usr/bin/env python3
"""Compat iter-9: capture the SCPU-Kicks detection compare via VICE cpuhistory.
Connect to the remote monitor EARLY (pauses at boot), set break $8142, resume,
catch the async breakpoint-hit (first arrival = clean history), dump cpuhistory."""
import socket, subprocess, time, os

VICE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
DISK = os.path.join(HERE, 'SCPU1.D64')
PORT = 6510

proc = subprocess.Popen([VICE, '-warp', '-autostart', DISK,
                         '-remotemonitor', '-remotemonitoraddress', 'ip4://127.0.0.1:%d' % PORT])
print('launched pid', proc.pid)
time.sleep(3)   # connect early, before detection runs

def recv_until(s, idle=2.5, hard=20):
    s.settimeout(1.0); out=b''; t0=time.time(); last=time.time()
    while time.time()-t0 < hard:
        try:
            d=s.recv(65536)
            if d: out+=d; last=time.time()
        except Exception:
            if out and time.time()-last>idle: break
            if time.time()-last>idle: break
    return out.decode('latin1')

def cmd(s, c, idle=2.0, hard=15):
    s.sendall((c+'\n').encode()); return recv_until(s, idle, hard)

try:
    s = socket.create_connection(('127.0.0.1', PORT), timeout=10)
    time.sleep(0.4)
    print('init:', repr(recv_until(s, idle=1.5, hard=4)[:120]))
    print('set BP:', cmd(s, 'break 8142')[:200])
    s.sendall(b'x\n')                       # resume; BP will pause on first $8142
    print('resumed, waiting for BP hit...')
    hit = recv_until(s, idle=3.0, hard=40)  # async breakpoint-hit notification
    print('=== BP HIT ===\n' + hit[-600:])
    hist = cmd(s, 'cpuhistory 600', idle=3.0, hard=25)
    open(os.path.join(HERE, 'detect_cpuhistory.txt'), 'w').write(hist)
    print('=== cpuhistory tail ===\n' + hist[-4500:])
    open(os.path.join(HERE, 'detect_disasm.txt'),'w').write(cmd(s,'d 80e0 8145', idle=1.5, hard=8))
    cmd(s, 'quit', idle=1.0, hard=3)
    s.close()
except Exception as e:
    print('monitor err:', e)

time.sleep(1)
try: proc.kill()
except Exception: pass
p=os.path.join(HERE,'detect_cpuhistory.txt')
print('history bytes:', os.path.getsize(p) if os.path.exists(p) else 0)
