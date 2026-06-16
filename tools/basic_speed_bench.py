#!/usr/bin/env python3
"""Real-software CPU-speed bench via a timed BASIC loop, typed over mtype.

Measures wall-clock jiffies (TI, the KERNAL 60Hz raster-IRQ clock) for a fixed
empty FOR/NEXT loop, in both t65 (6510) and scpu (SuperCPU) modes. The jiffy
clock counts REAL time (VIC IRQ is unchanged by CPU speed), so a faster CPU
finishes the loop in fewer jiffies. ratio = jiffies_t65 / jiffies_scpu =
the BASIC-code speed multiplier our SuperCPU delivers in EMULATION mode (BASIC
boots in 6502 emu mode; this tells us whether emu-mode BASIC gets the base
SuperCPU turbo even though the k=2 bank-$00 fast-fire is native-only).

Program typed (quote-free so no shifted chars):
  10 T=TI
  20 FORI=1TO30000:NEXT
  30 PRINTTI-T

Read the printed number off the screenshot per mode (overlay OFF via cfg 0x04/0x00).
Run when the rig is free. Usage: python tools/basic_speed_bench.py
"""
import os, sys, time, paramiko, hashlib

IP, OUT = '192.168.50.130', r'C:\LLM\C64\MiSTerSuperCPU\tools\basic_speed_bench'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64'
MODES = [('scpu', 0x04), ('t65', 0x00)]   # cfg byte10: bit2=supercpu, bit3=overlay(off)

def ssh():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(IP, username='root', password='1', timeout=15); return c

def run(c, cmd, t=20):
    _, o, e = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

def set_cfg(c, val):
    run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(val, CFG))

def core_mtime(c):
    return run(c, 'stat -c %Y /tmp/CORENAME 2>/dev/null').strip()

def shot(c, name):
    os.makedirs(OUT, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png; echo screenshot > /dev/MiSTer_cmd'); time.sleep(3)
    r = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not r: return None
    s = c.open_sftp(); local = os.path.join(OUT, name + '.png'); s.get(r, local); s.close()
    return local

def main():
    c = ssh()
    core = run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    if core not in ('', 'MENU', 'C64'):
        print('REFUSING: rig busy CORENAME="{}"'.format(core)); c.close(); return 2
    run(c, "echo 'agent=c64 task=basic_speed_bench' > /tmp/mister_session.lock")
    # upload mtype
    s = c.open_sftp(); s.put('tools/mtype.py', '/tmp/mtype.py'); s.close()
    for name, cfg in MODES:
        print('\n=== mode {} (cfg 0x{:02x}) ==='.format(name, cfg))
        set_cfg(c, cfg)
        pre = core_mtime(c)
        run(c, 'echo load_core {}.rbf > /dev/MiSTer_cmd'.format(RBF))
        dl = time.time() + 30
        while time.time() < dl:
            time.sleep(2)
            if core_mtime(c) != pre: break
        time.sleep(12)                      # boot to READY
        shot(c, name + '_0boot')
        # type the benchmark program + RUN (mtype creates uinput, ~6s settle)
        prog = ('"10 T=TI" enter "20 FORI=1TO30000:NEXT" enter '
                '"30 PRINTTI-T" enter "RUN" enter')
        run(c, 'python3 /tmp/mtype.py {} 2>&1'.format(prog), t=40)
        time.sleep(45)                      # let the loop finish (t65 ~2170 jiffies = 36s)
        p = shot(c, name + '_1result')
        print('  result shot ->', p)
    run(c, "echo NOLOCK > /tmp/mister_session.lock")
    c.close()
    print('\ndone ->', OUT, '\nRead the *_1result.png per mode; ratio = jiffies_t65 / jiffies_scpu')
    return 0

if __name__ == '__main__':
    sys.exit(main())
