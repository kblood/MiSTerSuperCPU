"""doom_v298_wedge_capture.py — load doom.reu + loader, then capture UART
continuously in long windows to catch the wedge transition (60-120s of v298).

v297 had main BRK-marching through bank $0F:$Axxx-$Bxxx with continuous
UART output through 240s. v298 (EPROM at bank $F8) has UART going silent
between 60s and 120s — Doom evidently calls into bank $F8 and that
crashes our partial SCPU environment.

This script captures the LAST frames before silence so we can see what
opcode/PC the CPU was running just before vblank IRQ stopped firing.

Output: tools/doom_full/v298_wedge_*.txt (one per capture window).
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    with open(LOADER_LOCAL,'rb') as f:
        with sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
    reu_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
               '<file delay="3" type="f" index="1" path="' + REU_REMOTE + '"/>\n'
               '</mistergamedescription>\n')
    loader_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                  '<file delay="3" type="f" index="1" path="' + LOADER_REMOTE + '"/>\n'
                  '</mistergamedescription>\n')
    with sftp.open(REU_MGL,'w') as f: f.write(reu_mgl)
    with sftp.open(LOADER_MGL,'w') as f: f.write(loader_mgl)
    with sftp.open(CFG,'rb+') as f: f.seek(10); f.write(bytes([0x84]))
    sftp.close()

    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB, 50s) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    t0 = time.time()
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Continuous 30-second UART windows starting at 30s.
    # If UART goes silent at ~80s, the 60-90s and 90-120s captures will
    # contain the transition.
    windows = [
        ('30-60',  30, 30),    # t=30..60
        ('60-90',  60, 30),    # t=60..90 (cumulative wait from t0)
        ('90-120', 90, 30),    # t=90..120
        ('120-150', 120, 30),  # t=120..150
        ('150-180', 150, 30),  # t=150..180
        ('180-240', 180, 60),  # t=180..240
    ]
    for label, t_start, dur in windows:
        # Wait until t_start since t0
        sleep_left = t_start - (time.time() - t0)
        if sleep_left > 0: time.sleep(sleep_left)
        print(f'  capturing window {label}s (duration {dur}s) ...')
        # Capture dur seconds of UART, save up to 32KB
        cmd = f'stty -F /dev/ttyS1 115200 raw -echo; timeout {dur} cat /dev/ttyS1 2>&1 | head -c 32768'
        out = run(cmd, t=dur + 10)
        path = os.path.join(OUT, f'v298_wedge_{label}.txt')
        with open(path, 'w', errors='replace') as f: f.write(out)
        # Summary: byte count + last frame
        nb = len(out.encode(errors='replace'))
        lines = [L for L in out.split('\n') if L.strip()]
        last = (lines[-1][:160]) if lines else '<empty>'
        print(f'    {nb} bytes, {len(lines)} frames, last: {last}')

    # Screenshot at end
    run('rm -f /media/fat/screenshots/C64/*.png 2>/dev/null')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'shot_v298_wedge_final.png'))
        sftp.close()
        print('screenshot saved')
    c.close()

if __name__ == '__main__':
    main()
