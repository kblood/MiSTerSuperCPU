#!/usr/bin/env python3
"""DL triage: deploy v207, set cfg=0x0C (SCPU+overlay), load DL, capture
N rapid screenshots, decode WPC field across them.

Goal: find PC of $DD00 writes. T65 baseline writes $DD00=$01 (correct
VIC bank 2 for DL bitmap). SCPU=on writes $00 / $02 (wrong) — capture
the PC where this happens to identify which DL routine misbehaves.
"""
import os, sys, time, paramiko

MISTER_HOST = '192.168.50.130'
MISTER_USER = 'root'
MISTER_PASS = '1'
RBF_LOCAL  = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.rbf'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
MGL_REMOTE = '/media/fat/_Test/DragonsLair_SuperCPU.mgl'
CFG_REMOTE = '/media/fat/config/C64.cfg'
SCREENS_REMOTE = '/media/fat/screenshots/C64'
SCREENS_LOCAL  = r'C:\LLM\C64\MiSTerSuperCPU\tools\dl_screens'

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER_HOST, username=MISTER_USER, password=MISTER_PASS, timeout=15)
    return c

def run(c, cmd):
    _, o, e = c.exec_command(cmd)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def deploy_rbf(c):
    sftp = c.open_sftp()
    print(f'[{time.strftime("%H:%M:%S")}] uploading rbf...')
    sftp.put(RBF_LOCAL, RBF_REMOTE)
    sftp.close()
    print(f'[{time.strftime("%H:%M:%S")}] rbf uploaded ({os.path.getsize(RBF_LOCAL)} bytes)')

def set_cfg_byte10(c, val):
    """Patch C64.cfg byte 10 to val (0x0C = SCPU + overlay)."""
    out, _ = run(c, f"dd if={CFG_REMOTE} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    print(f'  current cfg[10] = 0x{out.strip()}')
    run(c, f"printf '\\x{val:02x}' | dd of={CFG_REMOTE} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    out, _ = run(c, f"dd if={CFG_REMOTE} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    print(f'  patched cfg[10] = 0x{out.strip()}')

def load_core(c):
    run(c, f'echo load_core {RBF_REMOTE} > /dev/MiSTer_cmd')
    print(f'[{time.strftime("%H:%M:%S")}] load_core sent')
    time.sleep(8)

def load_mgl(c):
    # Stage 1: MGL loads dl00.reu (REU contents survive subsequent core
    # reload) plus dlair64ld.prg into BASIC RAM. But on vanilla-cpu-swap
    # there's no auto-RUN trigger for MGL-loaded PRGs, so step 2 fires it.
    run(c, f'echo load_core {MGL_REMOTE} > /dev/MiSTer_cmd')
    print(f'[{time.strftime("%H:%M:%S")}] mgl load sent (REU + PRG to RAM)')
    time.sleep(15)
    # Stage 2: mbc load_rom on the PRG resets C64 + auto-runs the
    # loaded program. SDRAM (REU contents) survives the reset.
    PRG = '/media/usb0/Games/C64/REU/DragonsLair/dlair64ld.prg'
    out, err = run(c, f'/media/fat/linux/mbc load_rom {PRG} C64')
    print(f'[{time.strftime("%H:%M:%S")}] mbc load_rom sent')
    if out.strip():
        print('  mbc out:', out.strip()[:200])
    if err.strip():
        print('  mbc err:', err.strip()[:200])
    time.sleep(20)  # DL decompressor takes ~10s

def burst_screenshots(c, n=15, period=1.2):
    for _ in range(n):
        run(c, 'echo screenshot > /dev/MiSTer_cmd')
        time.sleep(period)
    print(f'[{time.strftime("%H:%M:%S")}] {n} screenshots requested')

def fetch_recent_screenshots(c, n=15):
    """List most recent N screenshots, download to local."""
    out, _ = run(c, f'ls -t {SCREENS_REMOTE}/*.png 2>/dev/null | head -{n}')
    files = [l.strip() for l in out.splitlines() if l.strip()]
    sftp = c.open_sftp()
    os.makedirs(SCREENS_LOCAL, exist_ok=True)
    for f in files:
        local = os.path.join(SCREENS_LOCAL, os.path.basename(f))
        sftp.get(f, local)
    sftp.close()
    return [os.path.basename(f) for f in files]

def main():
    deploy = '--no-deploy' not in sys.argv
    n = 15
    if '--n' in sys.argv:
        n = int(sys.argv[sys.argv.index('--n')+1])
    cfg = 0x0C   # SCPU+overlay
    if '--t65' in sys.argv:
        cfg = 0x08  # overlay only, T65 path
    c = ssh()
    if deploy:
        deploy_rbf(c)
    set_cfg_byte10(c, cfg)
    load_core(c)
    load_mgl(c)
    burst_screenshots(c, n=n)
    time.sleep(2)
    files = fetch_recent_screenshots(c, n=n)
    c.close()
    print('\nDownloaded:')
    for f in files:
        print(f'  {f}')

if __name__ == '__main__':
    main()
