"""doom_v299_error_screen.py — boot Doom, time screenshot to catch
"Error: Bad music number -9" text BEFORE wedge corrupts video RAM.
Per transition_zoom data: error chain starts ~141s, wedge at ~142s.
Capture multiple shots over the 1-2 sec error window.
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
    print('load doom.reu (50s) ...'); run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg ...'); t0 = time.time()
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Time screenshots at multiple points to catch the error window
    targets = [135, 138, 140, 141, 142, 143, 145, 150, 160]
    for t_target in targets:
        sl = t_target - (time.time() - t0)
        if sl > 0: time.sleep(sl)
        run('rm -f /media/fat/screenshots/C64/*.png 2>/dev/null')
        run('echo screenshot > /dev/MiSTer_cmd')
        time.sleep(1.5)
        rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
        if rp:
            sftp = c.open_sftp()
            local_path = os.path.join(OUT, f'shot_v299_t{t_target}s.png')
            sftp.get(rp, local_path)
            sftp.close()
            print(f'  t={t_target}s -> {local_path}')

    c.close()

if __name__ == '__main__':
    main()
