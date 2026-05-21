#!/usr/bin/env python3
"""Retry DL + Doom MGL tests with long settle, t65 + scpu."""
import os, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_sweep2'

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c

def run(c, cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def cfg(c, val):
    run(c, f"printf '\\x{val:02x}' | dd of={CFG} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")

def core_mt(c):
    out,_ = run(c, "stat -c %Y /tmp/CORENAME")
    try: return int(out.strip())
    except: return 0

def shot(c, name):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    out,_ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rp = out.strip()
    if not rp: return None
    sftp = c.open_sftp()
    lp = os.path.join(OUT, f'{name}.png')
    sftp.get(rp, lp); sftp.close()
    return lp

def hash_mid(p):
    from PIL import Image
    img = Image.open(p)
    return hashlib.md5(img.crop((0, img.size[1]//4, img.size[0], img.size[1]*3//4)).tobytes()).hexdigest()[:12]

def run_mgl(c, label, mgl, settle, mode, val):
    print(f'--- {label} [{mode}] settle={settle}s ---')
    cfg(c, val)
    pre = core_mt(c)
    # Reset to clean BASIC first via plain rbf load
    run(c, f'echo load_core {RBF} > /dev/MiSTer_cmd')
    time.sleep(8)
    pre2 = core_mt(c)
    # Now load the MGL
    run(c, f'echo load_core {mgl} > /dev/MiSTer_cmd')
    deadline = time.time() + 25
    while time.time() < deadline:
        time.sleep(2)
        if core_mt(c) != pre2: break
    else:
        print('  WEDGE: MGL load_core mtime frozen')
        return 'WEDGE'
    print(f'  MGL accepted; settling {settle}s')
    time.sleep(settle)
    img = shot(c, f'{label}_{mode}_long')
    if img is None:
        print('  WEDGE: shot pipe dropped')
        return 'WEDGE-SHOT'
    print(f'  ok: {os.path.basename(img)} mid={hash_mid(img)}')
    return 'OK'

def main():
    c = ssh()
    try:
        # DL: 35s settle (REU is 16MB, takes time to load via load_core pipe)
        for mode, val in [('t65', 0x08), ('scpu', 0x0C)]:
            run_mgl(c, 'dl_long', '/media/fat/_Test/DragonsLair_SuperCPU.mgl', 35, mode, val)
        # Doom: 50s settle
        for mode, val in [('t65', 0x08), ('scpu', 0x0C)]:
            run_mgl(c, 'doom_long', '/media/fat/_Test/doom_full_abs.mgl', 50, mode, val)
    finally:
        c.close()

if __name__ == '__main__':
    main()
