"""v283 capture: doom full flow, then UART for 5s while Doom is in BRK loop.

The v283 latches mem_40/44/5C/45 are repurposed to hold the FIRST writer-PC
(24-bit) + first DATA byte for any write to $00:$6C03. UART G:## ## ##
shows writer-PC[7:0]/[15:8]/[23:16] and the byte at mem_45 position = first
DATA. All zero readout means Doom NEVER wrote to $00:$6C03.

Format reference: G:## ## ## carries mem_40, mem_44, mem_5C; mem_45 byte
appears in the UART line as part of the W5/N5 region (need to find which
field exactly).
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v283_first_writer')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    with open(LOADER_LOCAL,'rb') as f, sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
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

    print('reload core (v283) ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 120s for Doom to stall at $6C03 ...')
    time.sleep(120)
    # Capture UART for 5s — Doom is now in BRK loop (or stuck somewhere)
    print('capture UART for 5s ...')
    out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1 | head -c 8000', t=12)
    uart_path = os.path.join(OUT, 'uart.txt')
    with open(uart_path,'w',errors='replace') as f: f.write(out)
    print('UART -> ' + uart_path)
    # Print last 5 non-empty lines
    lines = [L for L in out.split('\n') if L.strip()]
    for L in lines[-5:]:
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
