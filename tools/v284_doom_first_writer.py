"""v284 capture: doom full flow, then UART for 15s.

Same v283 first-writer-PC latch, but gated on scpu_hwenable=1 so RAMTAS
KERNAL writes (PRE-Doom RAM clear at $00:$6C03 = $00) DON'T fire the latch.
Latch fires only when CPU writes $00:$6C03 AFTER Doom's STA $D07E (which
sets scpu_hwenable=1 at $20:$0041 in Doom's prologue).

UART G:## ## ## should now read either:
  - $00 $00 $00  → Doom NEVER writes to $00:$6C03 post-SCPU-enable.
                    BRK loop hypothesis stands (vector points at $6C03 by
                    coincidence of KERNAL ROM bytes, RAM there is $00=BRK).
  - $XX $XX $XX  → Doom DID write to $6C03 from PC $XX_XX_XX. Decode that
                    PC to find what value Doom expected at $6C03.

Also extends wait to 180s (Doom's bank-fill loops take time) and UART capture
to 15s for richer trace.
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v284_first_writer')

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

    print('reload core (v284) ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 180s for Doom to settle ...')
    time.sleep(180)
    print('capture UART for 15s ...')
    out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1 | head -c 32000', t=22)
    uart_path = os.path.join(OUT, 'uart.txt')
    with open(uart_path,'w',errors='replace') as f: f.write(out)
    print('UART -> ' + uart_path + ' (' + str(len(out)) + ' bytes)')
    lines = [L for L in out.split('\n') if L.strip()]
    print('lines: ' + str(len(lines)))
    # Print first 3 + last 5
    for L in lines[:3]:
        print('  FIRST: ' + L[:240])
    for L in lines[-5:]:
        print('  LAST:  ' + L[:240])
    # Extract G:## ## ## across all samples (writer-PC of first $00:$6C03 write)
    g_set = set()
    for L in lines:
        i = L.find('G:')
        if i >= 0 and i + 11 <= len(L):
            g_set.add(L[i:i+11])
    print('Unique G fields (first-writer-PC + DATA): ' + repr(g_set))
    # Screenshot
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('shot -> ' + os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
