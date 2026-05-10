"""Probe whether Doom is in a wait-for-input loop after the bank-$Fx
narrow stub. Loads doom flow, waits 2 min for stable wait-state, then
sequentially injects SPACE / RETURN / Y / joystick fire sequences and
captures UART after each. If AC growth rate changes or VIC writes
appear, that input was the trigger.
"""
import os, time, paramiko

HOST,USER,PASS = '192.168.50.130','root','1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/doom.reu'
REU_MGL = '/tmp/load_doom_reu.mgl'
LOADER_MGL = '/tmp/load_doom_loader.mgl'
MTYPE_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mtype.py')
MTYPE_REMOTE = '/tmp/mtype.py'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_input_probe')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=30):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')
    sftp = c.open_sftp()
    with open(LOADER_LOCAL,'rb') as f:
        with sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
    with open(MTYPE_LOCAL,'rb') as f:
        with sftp.open(MTYPE_REMOTE,'wb') as r: r.write(f.read())
    reu_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
               '<file delay="3" type="f" index="1" path="' + REU_REMOTE + '"/>\n</mistergamedescription>\n')
    loader_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                  '<file delay="3" type="f" index="1" path="' + LOADER_REMOTE + '"/>\n</mistergamedescription>\n')
    with sftp.open(REU_MGL,'w') as f: f.write(reu_mgl)
    with sftp.open(LOADER_MGL,'w') as f: f.write(loader_mgl)
    with sftp.open(CFG,'rb+') as f: f.seek(10); f.write(bytes([0x84]))
    sftp.close()

    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu ...'); run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg ...'); run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Wait for stable wait-loop state (per extended test, takes ~120s to enter)
    print('waiting 150s for stable wait-loop ...')
    time.sleep(150)

    def capture(label, t_sample=4):
        out = run(f'stty -F /dev/ttyS1 115200 raw -echo; timeout {t_sample} cat /dev/ttyS1 2>&1 | head -c 8000', t=t_sample+5)
        with open(os.path.join(OUT, 'uart_' + label + '.txt'),'w',errors='replace') as f: f.write(out)
        run('rm -f /media/fat/screenshots/C64/*.png')
        run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
        rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
        if rp:
            sftp2 = c.open_sftp(); sftp2.get(rp, os.path.join(OUT, 'shot_' + label + '.png')); sftp2.close()
        lines = [L for L in out.split('\n') if L.strip()]
        if lines: print(f'  [{label}] {lines[-1][:200]}')

    # Baseline at t=150s (wait-loop state)
    capture('baseline_150s')

    # Probe sequences: each followed by 30s wait + capture
    probes = [
        ('space',  'python3 ' + MTYPE_REMOTE + ' space'),
        ('return', 'python3 ' + MTYPE_REMOTE + ' return'),
        ('y',      'python3 ' + MTYPE_REMOTE + ' y'),
        ('esc',    'python3 ' + MTYPE_REMOTE + ' esc'),
        ('f1',     'python3 ' + MTYPE_REMOTE + ' f1'),
    ]
    for label, cmd in probes:
        print(f'  injecting [{label}] ...')
        out = run(cmd, t=10)
        if out.strip(): print(f'    mtype out: {out.strip()[:200]}')
        time.sleep(20)
        capture('after_' + label)
    c.close()

if __name__ == '__main__':
    main()
