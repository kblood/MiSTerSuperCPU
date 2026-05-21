#!/usr/bin/env python3
"""v272 sweep v2 — proven invocation paths + wedge detection.

Calls mister_debug.cmd_load_prg directly for PRG tests (verified working
in this session against decomp_stress.prg). Uses MGL load_core for MGL
tests. Wedge check after each load_core: monitors /tmp/CORENAME mtime
advance + screenshot pipe response. Reboot on wedge.
"""
import os, sys, time, hashlib, paramiko, subprocess

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_sweep2'

# (label, kind=prg/mgl, remote_path_or_local_for_prg, settle_seconds)
TESTS = [
    ('autorun_test', 'prg', r'tools/decomp_stress.prg',                 5),  # known-good baseline
    ('asterix_prg',  'mgl', '/media/fat/_Test/asterix.mgl',            10),
    ('dl_scpu',      'mgl', '/media/fat/_Test/DragonsLair_SuperCPU.mgl',20),
    ('doom',         'mgl', '/media/fat/_Test/doom_full_abs.mgl',      35),
    ('synthmark64',  'prg_remote', '/media/fat/games/C64/synthmark64.prg',8),
    ('scputest',     'prg_remote', '/media/fat/games/C64/scputest.prg',  8),
    ('autorun',      'prg_remote', '/media/fat/games/C64/autorun_test.prg',5),
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

def wait_for_core(c, prev_mt, max_wait=25):
    deadline = time.time() + max_wait
    while time.time() < deadline:
        time.sleep(2)
        if core_mtime(c) != prev_mt:
            return True
    return False

def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    remote = out.strip()
    if not remote:
        return None
    sftp = c.open_sftp()
    local = os.path.join(OUT, f'{name}.png')
    sftp.get(remote, local)
    sftp.close()
    return local

def hash_band(path, top=False):
    try:
        from PIL import Image
        img = Image.open(path)
        if top:
            crop = img.crop((0, 0, img.size[0], img.size[1] // 4))
        else:
            crop = img.crop((0, img.size[1] // 4, img.size[0], (img.size[1] * 3) // 4))
        return hashlib.md5(crop.tobytes()).hexdigest()[:12]
    except Exception as e:
        return f"ERR:{e}"

def reboot_mister(c):
    print("  ! sync && reboot — wait 60s")
    try:
        run(c, "sync; (sleep 1; reboot) &", timeout=5)
    except: pass
    try: c.close()
    except: pass
    time.sleep(60)
    for i in range(30):
        try:
            return ssh()
        except Exception:
            time.sleep(5)
    raise RuntimeError("MiSTer did not reboot")

def load_core_clean(c, label):
    pre_m = core_mtime(c)
    run(c, f'echo load_core {RBF} > /dev/MiSTer_cmd')
    if not wait_for_core(c, pre_m, 30):
        print(f"  [{label}] WEDGE: load_core didn't advance CORENAME mtime")
        return False
    time.sleep(8)  # settle to BASIC READY
    return True

def run_one(c, label, kind, path, settle, mode_label, cfg_val):
    print(f"--- {label} [{mode_label}] cfg=0x{cfg_val:02x} ---")
    set_cfg(c, cfg_val)
    pre_m = core_mtime(c)

    if kind == 'mgl':
        run(c, f'echo load_core {path} > /dev/MiSTer_cmd')
        if not wait_for_core(c, pre_m, 30):
            return c, 'WEDGE-MGL', None
        time.sleep(settle)
    elif kind == 'prg' or kind == 'prg_remote':
        # First clean-load core
        if not load_core_clean(c, label):
            return c, 'WEDGE-CORE', None
        if kind == 'prg':
            # Upload local PRG
            sftp = c.open_sftp()
            remote = '/media/fat/games/C64/' + os.path.basename(path)
            sftp.put(path, remote)
            sftp.close()
            inject_path = remote
        else:
            inject_path = path
        # Inject via mbc — proven syntax: mbc load_rom C64.PRG <path>
        out, err = run(c, f'/media/fat/linux/mbc load_rom C64.PRG {inject_path}', timeout=15)
        time.sleep(settle)
    else:
        return c, f'BAD-KIND:{kind}', None

    img = shot(c, f'{label}_{mode_label}')
    if img is None:
        return c, 'WEDGE-SHOT', None
    h_top = hash_band(img, top=True)
    h_mid = hash_band(img, top=False)
    print(f"  ok: {os.path.basename(img)} top={h_top} mid={h_mid}")
    return c, 'OK', (h_top, h_mid)

def main():
    os.makedirs(OUT, exist_ok=True)
    c = ssh()
    summary = []
    try:
        for label, kind, path, settle in TESTS:
            for mode_label, cfg_val in [('t65', 0x08), ('scpu', 0x0C)]:
                try:
                    c, status, h = run_one(c, label, kind, path, settle, mode_label, cfg_val)
                    summary.append((label, mode_label, status, h))
                    if 'WEDGE' in status:
                        print(f"  ! wedge: {status}")
                        c = reboot_mister(c)
                        c, st2, h2 = run_one(c, label, kind, path, settle, mode_label, cfg_val)
                        summary.append((label + '_RETRY', mode_label, st2, h2))
                except Exception as e:
                    print(f"  EXC {label}/{mode_label}: {e}")
                    summary.append((label, mode_label, f'EXC:{e}', None))
                    try: c.close()
                    except: pass
                    time.sleep(5)
                    c = ssh()
    finally:
        try: c.close()
        except: pass

    print("\n=== Summary ===")
    for row in summary:
        print(' '.join(str(x) for x in row))
    with open(os.path.join(OUT, '_summary.txt'), 'w') as fh:
        for row in summary:
            fh.write(' '.join(str(x) for x in row) + '\n')

if __name__ == '__main__':
    main()
