#!/usr/bin/env python3
"""Compat iter-9 HW ground-truth: load SCPU-Kicks, RUN it WITHOUT the fire-gate
poke so detection fails naturally on the MiSTer, then sample the overlay PC (UART)
to locate the fallback loop. Control build 97392a1f must be in _Test."""
import os, sys, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG  = '/media/fat/config/C64.cfg'
MGL  = '/media/fat/_Test/scpukicks_capture.mgl'
DISK = '/media/usb0/Games/C64/tools/SCPUKICK/SCPU1.D64'
MTYPE = '/media/fat/_Test/mtype.py'
OUT  = os.path.dirname(os.path.abspath(__file__))

def ssh():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15, look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(15); return c

def run(c, cmd, timeout=60):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def shot(c, name):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    remote = out.strip()
    if not remote: print('   [shot %s NONE]'%name); return None
    local = os.path.join(OUT, name+'.png')
    sftp=c.open_sftp(); sftp.get(remote, local); sftp.close()
    print('   [shot %s]'%name); return local

def mtype(c, *args):
    a=' '.join("'%s'"%x for x in args)
    out,_=run(c, 'python3 %s %s 2>&1'%(MTYPE,a), timeout=90)
    if out.strip(): print('   mtype:', out.strip()[:160])

def uart(c, secs):
    run(c, 'stty -F /dev/ttyS1 115200 raw -echo')
    out,_=run(c, 'timeout %d cat /dev/ttyS1'%secs, timeout=secs+10)
    return out

def main():
    c=ssh()
    core,_=run(c,'cat /tmp/CORENAME 2>/dev/null'); print('CORENAME=',repr(core.strip()))
    if core.strip() not in ('','MENU','C64'): print('not mine'); return 2
    run(c, "printf '\\x0c' | dd of=%s bs=1 count=1 seek=10 conv=notrunc 2>/dev/null"%CFG)
    mgl=('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
         '<file delay="2" type="s" index="0" path="%s"/>\n</mistergamedescription>\n')%DISK
    sftp=c.open_sftp()
    with sftp.open(MGL,'w') as f: f.write(mgl)
    sftp.close()
    print('mount disk...'); run(c,'echo load_core %s > /dev/MiSTer_cmd'%MGL); time.sleep(14)
    shot(c,'dr_boot')
    print('LOAD"*",8,1 ...'); mtype(c,'load"*",8,1','enter')
    print('waiting 90s for IEC load...')
    for t in range(30,95,30):
        time.sleep(30); p=shot(c,'dr_load_%02d'%t)
        print('   load t=%ds md5=%s'%(t, hashlib.md5(open(p,'rb').read()).hexdigest()[:8] if p else None))
    print('RUN (no poke - let detection fail naturally) ...')
    mtype(c,'run','enter'); time.sleep(5)
    shot(c,'dr_postrun_a')
    print('=== UART 8s after RUN ===')
    u=uart(c,8);
    open(os.path.join(OUT,'dr_uart.txt'),'w').write(u)
    # print last few overlay lines
    lines=[l for l in u.splitlines() if l.strip()]
    for l in lines[-12:]: print('  U:',l[:90])
    time.sleep(4); shot(c,'dr_postrun_b')
    print('=== UART 6s (later) ==='); u2=uart(c,6)
    for l in [x for x in u2.splitlines() if x.strip()][-8:]: print('  U:',l[:90])
    c.close(); print('DONE')
    return 0

if __name__=='__main__': sys.exit(main())
