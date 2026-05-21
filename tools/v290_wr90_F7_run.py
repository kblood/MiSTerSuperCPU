"""v290: Doom flow + UART capture. v290 RTL repurposes UART pool fields:

  G:## ## ##     = mem_40/44/5C = writer-PC of LAST "$F7 → $00:$0090" store
                                   = (PC_lo, PC_mid, PBR)
  B:##           = mem_45 = count of $F7 writes to $90

Doom hardcodes music_num=-9 ($FFF7) at $2C:$5D78 and $2C:$712C with
`LDA #$FFF7; STA $90`. Last-write capture pins which literal-load site
fires (or other code that writes $F7).

Expected match:
  $2C:$5D78 site → STA $90 at $5D7B → cpu_pc_now ≈ $5D7B-$5D7D → G:7B 5D 2C or G:7D 5D 2C
  $2C:$712C site → STA $90 at $712F → cpu_pc_now ≈ $712F-$7131 → G:2F 71 2C or G:31 71 2C

If G shows different bank ($2B?) or different low/mid bytes, then $F7
gets to $90 via runtime computation (e.g., arithmetic chain), not via
the hardcoded literal stores.

If B:00 or G:00 00 00, then $F7 was NEVER written to $90 in bank $00 —
suggests Doom uses a 16-bit STA from a different DBR or the music_num
gets to print via a path that doesn't touch $00:$0090 with $F7.
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v290_wr90_F7')

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

    print('reload core (v290) ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 180s for Doom to settle / hit music halt ...')
    time.sleep(180)
    print('capture UART for 15s ...')
    out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout 15 cat /dev/ttyS1 2>&1 | head -c 32000', t=22)
    uart_path = os.path.join(OUT, 'uart.txt')
    with open(uart_path,'w',errors='replace') as f: f.write(out)
    print('UART -> ' + uart_path + ' (' + str(len(out)) + ' bytes)')
    lines = [L for L in out.split('\n') if L.strip()]
    print('lines: ' + str(len(lines)))
    for L in lines[:2]:
        print('  FIRST: ' + L[:240])
    for L in lines[-3:]:
        print('  LAST:  ' + L[:240])
    g_set = set()
    b_set = set()
    for L in lines:
        i = L.find('G:')
        if i >= 0 and i + 11 <= len(L):
            g_set.add(L[i:i+11])
        j = L.find('B:')
        if j >= 0 and j + 5 <= len(L):
            b_set.add(L[j:j+5])
    print('Unique G fields (writer PC: lo mid bank): ' + repr(g_set))
    print('Unique B fields (count of $F7 writes): ' + repr(b_set))
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('shot -> ' + os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
