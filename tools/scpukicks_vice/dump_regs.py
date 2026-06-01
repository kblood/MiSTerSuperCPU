#!/usr/bin/env python3
"""Dump VICE xscpu64 $D000-$D0FF + $D200-$D3FF at the fire-gate (post-detection,
SuperCPU enabled) for comparison against our RTL register read mux."""
import socket, subprocess, time, os
VICE = r"C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\VICE-Team.VICE.GTK3_Microsoft.Winget.Source_8wekyb3d8bbwe\GTK3VICE-3.10-win64\bin\xscpu64.exe"
HERE = os.path.dirname(os.path.abspath(__file__)); DISK=os.path.join(HERE,'SCPU1.D64'); PORT=6510
proc=subprocess.Popen([VICE,'-warp','-autostart',DISK,'-remotemonitor','-remotemonitoraddress','ip4://127.0.0.1:%d'%PORT])
time.sleep(12)
def ru(s,idle=1.0,hard=8):
    s.settimeout(0.6);out=b'';t0=time.time();last=time.time()
    while time.time()-t0<hard:
        try:
            d=s.recv(65536)
            if d:out+=d;last=time.time()
        except:
            if time.time()-last>idle:break
    return out.decode('latin1')
def cmd(s,c,idle=1.2,hard=8):
    s.sendall((c+'\n').encode());return ru(s,idle,hard)
try:
    s=socket.create_connection(('127.0.0.1',PORT),timeout=10);time.sleep(0.4);ru(s,0.8,3)
    print('PC:',cmd(s,'r').strip()[:90])
    out=''
    out+='=== $D000-$D0FF ===\n'+cmd(s,'m d000 d0ff',1.5,8)
    out+='\n=== $D200-$D3FF ===\n'+cmd(s,'m d200 d3ff',2.0,10)
    open(os.path.join(HERE,'vice_regdump.txt'),'w').write(out)
    print(out[:3000])
    cmd(s,'quit',0.5,3);s.close()
except Exception as e: print('err',e)
time.sleep(1)
try: proc.kill()
except: pass
