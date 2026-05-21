"""Run flow:
1. Load Doom (full flow: doom.reu + loader.prg) — populates SuperRAM.
2. Wait until Doom is stuck at $6C03 (~120s).
3. Load peek_bank01_6c00.prg via MGL — SDRAM survives core reload.
4. Capture UART — v282 latches mem_40/44/5C show bank $01:$6C00/$03/$05 contents.

cfg byte 10 = 0x84 (SCPU + UART) is set via SFTP.
"""
import os, time, paramiko

HOST,USER,PASS = '192.168.50.130','root','1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
PEEK_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_bank01_6c00.prg')
LOADER_REMOTE = '/tmp/loader.prg'
PEEK_REMOTE = '/tmp/peek_bank01.prg'
REU_REMOTE = '/media/fat/games/C64/doom.reu'
REU_MGL = '/tmp/load_doom_reu.mgl'
LOADER_MGL = '/tmp/load_doom_loader.mgl'
PEEK_MGL = '/tmp/load_peek.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'peek_bank01_6c00')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    # Upload loader.prg + peek.prg
    with open(LOADER_LOCAL,'rb') as f, sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
    with open(PEEK_LOCAL,'rb') as f, sftp.open(PEEK_REMOTE,'wb') as r: r.write(f.read())
    # MGLs
    reu_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
               '<file delay="3" type="f" index="1" path="' + REU_REMOTE + '"/>\n'
               '</mistergamedescription>\n')
    loader_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                  '<file delay="3" type="f" index="1" path="' + LOADER_REMOTE + '"/>\n'
                  '</mistergamedescription>\n')
    peek_mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
                '<file delay="3" type="f" index="1" path="' + PEEK_REMOTE + '"/>\n'
                '</mistergamedescription>\n')
    with sftp.open(REU_MGL,'w') as f: f.write(reu_mgl)
    with sftp.open(LOADER_MGL,'w') as f: f.write(loader_mgl)
    with sftp.open(PEEK_MGL,'w') as f: f.write(peek_mgl)
    # cfg byte 10 = 0x84
    with sftp.open(CFG,'rb+') as f: f.seek(10); f.write(bytes([0x84]))
    sftp.close()

    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 90s for Doom to stall at $6C03 ...')
    time.sleep(90)
    print('load peek_bank01_6c00.prg (SDRAM persists) ...')
    run('echo load_core ' + PEEK_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(15)
    # Capture UART
    print('capture UART for 5s ...')
    out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1 | head -c 8000', t=12)
    uart_path = os.path.join(OUT, 'uart_peek.txt')
    with open(uart_path,'w',errors='replace') as f: f.write(out)
    print('UART -> ' + uart_path)
    # Print last 3 lines
    lines = [L for L in out.split('\n') if L.strip()]
    for L in lines[-3:]:
        print('  ' + L[:240])
    # Screenshot
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
    c.close()

if __name__ == '__main__':
    main()
