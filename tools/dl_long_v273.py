#!/usr/bin/env python3
"""DL 35s-settle confirmation re-run for v273 Phase 2 build."""
import paramiko, time, os, hashlib
HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v272_sweep2'


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c


def run(c, cmd, t=20):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def set_cfg(c, v):
    cmd = "printf '" + chr(92) + "x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(v, CFG)
    run(c, cmd)


def shot(c, name):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rm = out.strip()
    sftp = c.open_sftp()
    local = os.path.join(OUT, name + '.png')
    sftp.get(rm, local)
    sftp.close()
    return local


def hash_band(p, top=False):
    from PIL import Image
    img = Image.open(p)
    if top:
        crop = img.crop((0, 0, img.size[0], img.size[1] // 4))
    else:
        crop = img.crop((0, img.size[1] // 4, img.size[0], (img.size[1] * 3) // 4))
    return hashlib.md5(crop.tobytes()).hexdigest()[:12]


def main():
    c = ssh()
    for mode, val in [('t65', 0x08), ('scpu', 0x0C)]:
        print('--- DL [{}] cfg=0x{:02x} 35s settle ---'.format(mode, val))
        set_cfg(c, val)
        run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(RBF))
        time.sleep(8)
        run(c, 'echo load_core /media/fat/_Test/DragonsLair_SuperCPU.mgl > /dev/MiSTer_cmd')
        time.sleep(35)
        p = shot(c, 'dl_long_' + mode + '_v273')
        print('  ok: {} top={} mid={}'.format(os.path.basename(p), hash_band(p, True), hash_band(p, False)))
    c.close()


if __name__ == '__main__':
    main()
