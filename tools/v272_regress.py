#!/usr/bin/env python3
"""v272 regression sweep: cold-boot to BASIC READY in T65 + SCPU modes.

For each mode: patch cfg[10], reload core, wait for boot, screenshot.
PASS criterion (visual): screenshot shows BASIC READY prompt.
"""
import os, sys, time, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_regress'

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c

def run(c, cmd, timeout=30):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def set_cfg(c, val):
    run(c, f"printf '\\x{val:02x}' | dd of={CFG} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    out, _ = run(c, f"dd if={CFG} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    return out.strip()

def reload(c):
    run(c, f'echo load_core {RBF} > /dev/MiSTer_cmd')
    time.sleep(8)

def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    remote = out.strip()
    if not remote:
        print(f'  {name}: no screenshot file produced')
        return
    sftp = c.open_sftp()
    local = os.path.join(OUT, f'{name}.png')
    sftp.get(remote, local)
    sftp.close()
    sz = os.path.getsize(local)
    print(f'  {name}: {sz} bytes -> {local}')

def main():
    c = ssh()
    for mode, val in [('t65_basic', 0x08), ('scpu_basic', 0x0C)]:
        print(f'=== {mode} cfg=0x{val:02x} ===')
        got = set_cfg(c, val)
        print(f'  cfg[10] = 0x{got}')
        reload(c)
        shot(c, mode)
        time.sleep(1)
    c.close()
    print('Done.')

if __name__ == '__main__':
    main()
