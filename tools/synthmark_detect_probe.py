#!/usr/bin/env python3
"""SynthMark64 SuperRAM-detection probe (HW, unattended).

Loads SynthMark64 v0.2 in SuperCPU mode with the debug overlay OFF (cfg 0x04)
and captures the menu screenshot, whose status line reads
`CPU 65816, RAM <KB> KB (<N> BANKS) PAL`.

Used to validate the iter-33c SIMM-detect cap (c64.sv SIMM_CAP). Before the fix
the line reads `0 KB (0 BANKS)` (256-bank wraparound). After the fix, capping CPU
reads of SuperRAM banks $F0-$FE makes the bank-walk probe terminate at $F0, so the
line should read `15360 KB (240 BANKS)`.

Read the result off tools/synthmark/detect_menu.png.
COOPERATION: refuses to load_core unless /tmp/CORENAME is C64/MENU/empty.

Usage: python tools/synthmark_detect_probe.py
"""
import os, sys, time, paramiko

IP = '192.168.50.130'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\synthmark'
CFG = '/media/fat/config/C64.cfg'
PRG = '/media/fat/games/C64/synthmark64.prg'
MGL = '/media/fat/_Test/synthmark.mgl'


def ssh():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(IP, username='root', password='1', timeout=15); return c


def run(c, cmd, t=20):
    _, o, e = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')


def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png; echo screenshot > /dev/MiSTer_cmd'); time.sleep(3)
    p = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not p: return None
    s = c.open_sftp(); local = os.path.join(OUT, name + '.png'); s.get(p, local); s.close()
    return local


def main():
    c = ssh()
    core = run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    if core not in ('', 'MENU', 'C64'):
        print('REFUSING: rig busy CORENAME="{}"'.format(core)); c.close(); return 2
    run(c, "echo 'agent=c64 task=synthmark_detect' > /tmp/mister_session.lock")
    # scpu mode, overlay OFF
    run(c, "printf '\\x04' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(CFG))
    mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
           '<file delay="6" type="f" index="1" path="{}"/>\n'
           '</mistergamedescription>\n').format(PRG)
    s = c.open_sftp()
    with s.open(MGL, 'w') as f: f.write(mgl)
    s.close()
    pre = run(c, 'stat -c %Y /tmp/CORENAME 2>/dev/null').strip()
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(MGL))
    dl = time.time() + 30
    while time.time() < dl:
        time.sleep(2)
        if run(c, 'stat -c %Y /tmp/CORENAME 2>/dev/null').strip() != pre: break
    time.sleep(20)                       # boot + autoload to the menu
    p = shot(c, 'detect_menu')
    print('menu shot ->', p)
    print('Read the RAM line: expect "15360 KB (240 BANKS)" with the SIMM_CAP fix '
          '(was "0 KB (0 BANKS)").')
    run(c, "echo NOLOCK > /tmp/mister_session.lock")
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
