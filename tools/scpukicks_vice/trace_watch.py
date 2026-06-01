#!/usr/bin/env python3
"""Compat iter-9: trace SCPU-Kicks detection mechanism in VICE (golden=PASS).
Launch xscpu64 NO-warp, connect early, set watchpoints on the turbo regs
($D07A/$D07B) and CIA timer reads, then autostart. Each hit dumps PC+regs+value
-> reveals whether detection is a speed/timing test or a register read."""
import socket, subprocess, time, os

VICE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
DISK = os.path.join(HERE, 'SCPU1.D64')
PORT = 6510

# NO warp so we have time to set watchpoints before the loader runs detection
proc = subprocess.Popen([VICE, '-autostart', DISK,
                         '-remotemonitor', '-remotemonitoraddress', 'ip4://127.0.0.1:%d' % PORT])
print('launched pid', proc.pid)
time.sleep(2)

def ru(s, idle=1.0, hard=10):
    s.settimeout(0.6); out=b''; t0=time.time(); last=time.time()
    while time.time()-t0 < hard:
        try:
            d=s.recv(65536)
            if d: out+=d; last=time.time()
        except Exception:
            if time.time()-last>idle: break
    return out.decode('latin1')

def cmd(s, c, idle=1.0, hard=10):
    s.sendall((c+'\n').encode()); return ru(s, idle, hard)

try:
    s = socket.create_connection(('127.0.0.1', PORT), timeout=10)
    time.sleep(0.4); ru(s, 0.8, 3)
    # watch stores to turbo control + loads from CIA timers (CPU-speed measurement)
    for w in ['watch load $d070 $d0ff']:
        print('+', w, '->', cmd(s, w).strip()[:80])
    log = open(os.path.join(HERE, 'detect_watch.txt'), 'w')
    s.sendall(b'x\n')                        # resume
    print('resumed (no warp); collecting watch hits...')
    hits = 0
    t0 = time.time()
    while hits < 60 and time.time()-t0 < 75:
        chunk = ru(s, idle=2.5, hard=8)      # wait for an async watch-hit notification
        if not chunk.strip():
            continue
        # on a hit, monitor is active; grab regs then resume
        regs = cmd(s, 'r', idle=0.8, hard=4)
        line = (chunk.strip() + ' || ' + ' '.join(regs.split())).replace('\n',' ')
        print('HIT%02d: %s' % (hits, line[:200]))
        log.write(line + '\n'); log.flush()
        hits += 1
        s.sendall(b'x\n')                     # continue to next hit
    log.close()
    cmd(s, 'quit', 0.5, 3); s.close()
except Exception as e:
    print('monitor err:', e)

time.sleep(1)
try: proc.kill()
except Exception: pass
print('done -> detect_watch.txt')
