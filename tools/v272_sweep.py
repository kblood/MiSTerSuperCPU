#!/usr/bin/env python3
"""v272 regression sweep with daemon-wedge detection.

Tests each title under T65 then SCPU mode, takes screenshots, and watches for
the known MiSTer daemon wedge symptom: /tmp/CORENAME mtime fails to advance
past a load_core, screenshot pipe silently drops requests. On wedge we issue
`sync && reboot` and resume.

Sweep targets (all already on /media/fat):
  - asterix.prg            (PRG via mbc load_rom)
  - autorun_test.prg       (PRG)
  - synthmark64.prg        (PRG)
  - scputest.prg           (PRG)
  - DragonsLair (SCPU)     (MGL — REU + PRG)
  - Doom (SCPU)            (MGL — REU + loader)

For each, T65 oracle screenshot first (cfg[10]=0x08), then SCPU
(cfg[10]=0x0C), saved side-by-side. Pixel-hash equality NOT used as
pass/fail — many of these have animation/timing variance — instead we
check for: (a) screenshot taken at all, (b) no boot freeze, (c) cold-boot
state on either side of the test.
"""
import os, sys, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_sweep'

# (label, prg-path on remote, None) for PRGs;  (label, mgl-path, 'mgl') for MGLs
TESTS = [
    ('autorun_test', '/media/fat/games/C64/autorun_test.prg', None,  4),
    ('asterix',      '/media/fat/games/C64/asterix.prg',       None, 6),
    ('scputest',     '/media/fat/games/C64/scputest.prg',      None, 6),
    ('synthmark64',  '/media/fat/games/C64/synthmark64.prg',   None, 8),
    ('asterix_mgl',  '/media/fat/_Test/asterix.mgl',           'mgl',12),
    ('dl_scpu_mgl',  '/media/fat/_Test/DragonsLair_SuperCPU.mgl','mgl',18),
    ('doom_full',    '/media/fat/_Test/doom_full_abs.mgl',     'mgl',30),
]

def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c

def run(c, cmd, timeout=20):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')

def set_cfg(c, val):
    run(c, f"printf '\\x{val:02x}' | dd of={CFG} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    out, _ = run(c, f"dd if={CFG} bs=1 count=1 skip=10 2>/dev/null | xxd -p")
    return out.strip()

def core_mtime(c):
    out, _ = run(c, "stat -c %Y /tmp/CORENAME 2>/dev/null")
    try: return int(out.strip())
    except: return 0

def fb_dmesg_tail(c):
    out, _ = run(c, "dmesg | grep -c MiSTer_fb")
    try: return int(out.strip())
    except: return 0

def detect_wedge(c, prev_core_mtime, prev_fb_count, label, max_wait=30):
    """Returns 'OK' | 'WEDGED'"""
    deadline = time.time() + max_wait
    while time.time() < deadline:
        time.sleep(2)
        m = core_mtime(c)
        f = fb_dmesg_tail(c)
        if m != prev_core_mtime:
            print(f"  [wedge-check {label}] CORENAME mtime advanced ({prev_core_mtime}->{m}); fb_events={f-prev_fb_count}")
            return 'OK'
    print(f"  [wedge-check {label}] CORENAME mtime FROZEN at {prev_core_mtime} after {max_wait}s — WEDGED")
    return 'WEDGED'

def reboot_mister(c):
    print("  ! issuing sync && reboot — wait 60s for MiSTer to come back")
    try:
        run(c, "sync; (sleep 1; reboot) &", timeout=5)
    except Exception as e:
        print(f"  reboot exec error (ignored): {e}")
    try: c.close()
    except: pass
    time.sleep(60)
    # Reconnect loop
    for _ in range(30):
        try:
            c2 = ssh()
            print("  reconnected after reboot")
            return c2
        except Exception:
            time.sleep(5)
    raise RuntimeError("MiSTer did not come back after reboot")

def reload_core(c):
    run(c, f'echo load_core {RBF} > /dev/MiSTer_cmd')

def load_mgl(c, mgl_path):
    run(c, f'echo load_core {mgl_path} > /dev/MiSTer_cmd')

def load_prg(c, prg_path):
    # mbc load_rom C64 path, mode 1 (autorun PRG)
    run(c, f'/media/fat/linux/mbc load_rom C64 {prg_path}', timeout=20)

def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    remote = out.strip()
    if not remote:
        return None
    sftp = c.open_sftp()
    local = os.path.join(OUT, f'{name}.png')
    sftp.get(remote, local)
    sftp.close()
    return local

def hash_topband(path):
    try:
        from PIL import Image
        img = Image.open(path)
        # Hash the top 25% — signature of "did anything render"
        h25 = img.size[1] // 4
        crop = img.crop((0, 0, img.size[0], h25))
        return hashlib.md5(crop.tobytes()).hexdigest()[:12]
    except Exception as e:
        return f"ERR:{e}"

def run_one(c, label, path, kind, settle, mode_label, cfg_val):
    print(f"--- {label} [{mode_label}] ---")
    set_cfg(c, cfg_val)
    pre_m = core_mtime(c)
    pre_f = fb_dmesg_tail(c)
    if kind == 'mgl':
        load_mgl(c, path)
    else:
        # plain prg — first ensure C64 core is up, then mbc-inject
        reload_core(c)
        wedge = detect_wedge(c, pre_m, pre_f, label + ' core-load')
        if wedge == 'WEDGED':
            return c, 'WEDGED-CORE', None
        time.sleep(8)  # extra wait for BASIC READY before injecting PRG
        load_prg(c, path)
    time.sleep(settle)
    img = shot(c, f'{label}_{mode_label}')
    if img is None:
        # Pipe might be wedged
        return c, 'WEDGED-SHOT', None
    h = hash_topband(img)
    print(f"  ok: {os.path.basename(img)} top25%-md5={h}")
    return c, 'OK', h

def main():
    os.makedirs(OUT, exist_ok=True)
    c = ssh()
    summary = []
    try:
        for label, path, kind, settle in TESTS:
            for mode_label, cfg_val in [('t65', 0x08), ('scpu', 0x0C)]:
                try:
                    c, status, h = run_one(c, label, path, kind, settle, mode_label, cfg_val)
                    summary.append((label, mode_label, status, h))
                    if 'WEDGED' in status:
                        print(f"  ! wedge during {label}/{mode_label}: {status}")
                        c = reboot_mister(c)
                        # Retry once
                        c, status2, h2 = run_one(c, label, path, kind, settle, mode_label, cfg_val)
                        summary.append((label + '_RETRY', mode_label, status2, h2))
                except Exception as e:
                    print(f"  EXC {label}/{mode_label}: {e}")
                    summary.append((label, mode_label, f'EXC:{e}', None))
                    # try to recover
                    try: c.close()
                    except: pass
                    time.sleep(3)
                    c = ssh()
    finally:
        try: c.close()
        except: pass

    print("\n=== Summary ===")
    for row in summary:
        print(' '.join(str(x) for x in row))
    # Persist to disk
    with open(os.path.join(OUT, '_summary.txt'), 'w') as fh:
        for row in summary:
            fh.write(' '.join(str(x) for x in row) + '\n')

if __name__ == '__main__':
    main()
