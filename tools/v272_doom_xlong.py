#!/usr/bin/env python3
"""Doom MGL retry with 80s settle to allow REU->SuperRAM transfer to finish."""
import os, time, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_sweep2'

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c

def run(c, cmd, t=15):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')

def setcfg(c, v):
    run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(v, CFG))

def shot(c, name):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not rp:
        return None
    sftp = c.open_sftp()
    lp = os.path.join(OUT, name + '.png')
    sftp.get(rp, lp)
    sftp.close()
    return lp

def main():
    c = ssh()
    try:
        for mode, val in [('t65', 0x08), ('scpu', 0x0C)]:
            print('--- doom_xlong [{}] ---'.format(mode))
            setcfg(c, val)
            run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
            time.sleep(8)
            run(c, 'echo load_core /media/fat/_Test/doom_full_abs.mgl > /dev/MiSTer_cmd')
            print('  settling 80s')
            time.sleep(80)
            img = shot(c, 'doom_xlong_' + mode)
            print('  saved: ' + str(img))
    finally:
        c.close()

if __name__ == '__main__':
    main()
