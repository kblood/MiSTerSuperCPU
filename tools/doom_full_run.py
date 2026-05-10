"""Run the FULL Doom flow: load doom.reu first, wait, then load loader.prg
(autorun) and capture UART. SCPU enabled via SFTP cfg byte 10 = 0x84.

Two-step MGL is the right pattern (per memory project_doom_reu_loading_mbc_broken.md):
  1. doom.reu via MGL -> populates REU SDRAM (16MB transfer ~30-40s)
  2. loader.prg via MGL -> autoruns the 254-byte covert-bitops loader

Captures UART at 60s and 240s. Saves screenshots."""
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

    cfg_dump = run('xxd ' + CFG + ' | head -1')
    print('cfg byte 10 (verify):', cfg_dump.strip())

    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB transfer, wait 50s) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Snapshot at intervals + UART captures
    for label, t_target in [('30s', 30), ('60s', 60), ('120s', 120), ('240s', 240)]:
        # Sleep until target
        t0 = time.time()
        while time.time() - t0 < t_target / 4:  # incremental
            time.sleep(1)
        if t_target == 30:
            time.sleep(15)
        elif t_target == 60:
            time.sleep(15)
        elif t_target == 120:
            time.sleep(45)
        else:
            time.sleep(105)
        # Capture UART
        out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout 4 cat /dev/ttyS1 2>&1 | head -c 8000', t=10)
        with open(os.path.join(OUT, 'uart_' + label + '.txt'),'w',errors='replace') as f: f.write(out)
        # Screenshot
        run('rm -f /media/fat/screenshots/C64/*.png')
        run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
        rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
        if rp:
            sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot_' + label + '.png')); sftp.close()
        # Print last UART line
        lines = [L for L in out.split('\n') if L.strip()]
        if lines:
            print('  t=' + label + ':')
            print('    ' + lines[-1][:240])
    c.close()

if __name__ == '__main__':
    main()
