#!/usr/bin/env python3
"""DL UART triage: capture per-frame DBG_UART pool dump for T65 and SCPU.

Workflow (no OSD navigation):
  1. SCP rbf to /media/fat/_Test/C64.rbf (skip with --no-deploy)
  2. Patch /media/fat/config/C64.cfg byte 10 to select T65 (0x08) or
     SCPU (0x0C). Bit 2 = status[82] (SCPU), bit 3 = status[83] (overlay).
     dbg_uart_en is currently hardcoded ON (commit 4eb43e0) so we don't
     need to set bit 7.
  3. load_core via /dev/MiSTer_cmd
  4. Load DragonsLair via MGL (REU + RAM-staged PRG)
  5. mbc load_rom the launcher PRG to reset + auto-run
  6. Capture UART for SECONDS seconds via cat /dev/ttyS1
  7. Save trace to tools/dl_uart_<mode>_<timestamp>.txt

Two-shot run (default): does T65 then SCPU back-to-back so screenshots
and traces are time-aligned.

Usage:
  python tools/dl_uart_capture.py                   # both T65 and SCPU
  python tools/dl_uart_capture.py --t65             # T65 only
  python tools/dl_uart_capture.py --scpu            # SCPU only
  python tools/dl_uart_capture.py --no-deploy       # don't re-upload rbf
  python tools/dl_uart_capture.py --seconds 30      # capture window
"""
import os, sys, time, paramiko

MISTER_HOST = '192.168.50.130'
MISTER_USER = 'root'
MISTER_PASS = '1'
RBF_LOCAL  = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.rbf'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
MGL_REMOTE = '/media/fat/_Test/DragonsLair_SuperCPU.mgl'
CFG_REMOTE = '/media/fat/config/C64.cfg'
LAUNCHER_PRG = '/media/usb0/Games/C64/REU/DragonsLair/dlair64ld.prg'

OUT_DIR = r'C:\LLM\C64\MiSTerSuperCPU\tools'

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER_HOST, username=MISTER_USER, password=MISTER_PASS, timeout=15)
    return c

def run(c, cmd, timeout=30):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def deploy_rbf(c):
    sftp = c.open_sftp()
    print(f'[{time.strftime("%H:%M:%S")}] uploading rbf ({os.path.getsize(RBF_LOCAL)} bytes)...')
    sftp.put(RBF_LOCAL, RBF_REMOTE)
    sftp.close()
    print(f'[{time.strftime("%H:%M:%S")}] rbf uploaded')

def set_cfg_byte10(c, val):
    out, _ = run(c, f"dd if={CFG_REMOTE} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    print(f'  current cfg[10] = 0x{out.strip()}')
    run(c, f"printf '\\x{val:02x}' | dd of={CFG_REMOTE} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    out, _ = run(c, f"dd if={CFG_REMOTE} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    print(f'  patched cfg[10] = 0x{out.strip()}  (bit2=SCPU, bit3=overlay)')

def load_core(c):
    run(c, f'echo load_core {RBF_REMOTE} > /dev/MiSTer_cmd')
    print(f'[{time.strftime("%H:%M:%S")}] load_core sent')
    time.sleep(8)

def load_dl(c):
    run(c, f'echo load_core {MGL_REMOTE} > /dev/MiSTer_cmd')
    print(f'[{time.strftime("%H:%M:%S")}] mgl load sent (REU + PRG to RAM)')
    time.sleep(15)
    out, err = run(c, f'/media/fat/linux/mbc load_rom {LAUNCHER_PRG} C64')
    print(f'[{time.strftime("%H:%M:%S")}] launcher PRG fired (mbc load_rom)')
    if out.strip():
        print('  mbc out:', out.strip()[:200])
    if err.strip():
        print('  mbc err:', err.strip()[:200])
    print(f'[{time.strftime("%H:%M:%S")}] waiting 20s for DL decompressor...')
    time.sleep(20)

def capture_uart(c, seconds, out_path):
    run(c, "stty -F /dev/ttyS1 115200 raw -echo")
    print(f'[{time.strftime("%H:%M:%S")}] capturing UART for {seconds}s -> {out_path}')
    out, err = run(c, f'timeout {seconds} cat /dev/ttyS1 2>/dev/null', timeout=seconds + 10)
    if not out.strip():
        print(f'  WARNING: no UART output captured. DBG_UART hardcoded on?')
    with open(out_path, 'w', encoding='utf-8', errors='replace') as f:
        f.write(out)
    n = sum(1 for line in out.splitlines() if line.strip())
    print(f'  saved {len(out)} bytes ({n} lines)')
    return n

def run_one(c, mode, deploy, seconds):
    """mode in {'t65', 'scpu'}."""
    cfg = 0x08 if mode == 't65' else 0x0C
    print(f'\n=== {mode.upper()} run (cfg[10]=0x{cfg:02X}) ===')
    if deploy:
        deploy_rbf(c)
        deploy = False  # only deploy once across multi-run
    set_cfg_byte10(c, cfg)
    load_core(c)
    load_dl(c)
    ts = time.strftime('%Y%m%dT%H%M%S')
    out_path = os.path.join(OUT_DIR, f'dl_uart_{mode}_{ts}.txt')
    n_lines = capture_uart(c, seconds, out_path)
    return out_path, n_lines

def summarize(path, label):
    """Quick stats: line count, frame range, unique PCs, unique V0..V3."""
    if not os.path.exists(path):
        print(f'{label}: file not found')
        return
    pcs = set()
    v_seen = set()
    cy_first, cy_last = None, None
    f_first, f_last = None, None
    n = 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        n += 1
        # F:#### PC:###### P:## V:## ## ## ## YX:#### WP:###### CG:#### CY:####
        toks = line.split()
        try:
            f  = toks[0].split(':')[1]
            pc = toks[1].split(':')[1]
            cy = toks[-1].split(':')[1]
            v_ring = ' '.join(t for t in toks if t in [toks[3].split(':')[1]] or False) or ''
        except Exception:
            continue
        pcs.add(pc)
        if cy_first is None:
            cy_first, f_first = cy, f
        cy_last, f_last = cy, f
    print(f'{label}: {n} lines  F:{f_first}->{f_last}  CY:{cy_first}->{cy_last}  unique-PCs:{len(pcs)}')

def main():
    deploy = '--no-deploy' not in sys.argv
    seconds = 30
    if '--seconds' in sys.argv:
        seconds = int(sys.argv[sys.argv.index('--seconds')+1])
    only_t65 = '--t65' in sys.argv
    only_scpu = '--scpu' in sys.argv
    modes = ['t65', 'scpu']
    if only_t65 and not only_scpu:
        modes = ['t65']
    elif only_scpu and not only_t65:
        modes = ['scpu']

    c = ssh()
    paths = {}
    for m in modes:
        path, n = run_one(c, m, deploy, seconds)
        deploy = False
        paths[m] = path
    c.close()

    print('\n=== Summary ===')
    for m, p in paths.items():
        summarize(p, m.upper())
        print(f'  trace: {p}')

if __name__ == '__main__':
    main()
