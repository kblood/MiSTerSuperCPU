"""v289: Doom flow + UART capture. v289 RTL repurposes UART pool fields:

  B:##           = pool.mem_45 = music_num LOW byte snap from $2B:$1A22 (STA $94)
  G:## ## ##     = pool.mem_40, mem_44, mem_5C
                   = $0074 dispatch low / music_num HIGH from $2B:$1A26 (STA $96) /
                     $0076 dispatch bank
                 (mem_44 was $0075 dispatch mid byte, dropped — music_num high
                  is more useful since dispatch mid is known $59 from prior runs)

For music_num = -9 = $FFF7 (signed 16-bit), expect:
  B:F7          (low byte)
  G:F6 FF 2C    (dispatch_lo / music_high=$FF / dispatch_bank=$2C)

If music_num is some other value, B/G fields show its actual bytes.
B:00 G:## 00 ## means snapshot trigger never fired (PC never reached $2B:$1A2x
during write to $94/$96) — meaning music check at $2B:$1A20 isn't on the
actual error path.
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v289_music_snap')

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

    print('reload core (v289) ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
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
    for L in lines[:3]:
        print('  FIRST: ' + L[:240])
    for L in lines[-5:]:
        print('  LAST:  ' + L[:240])
    # Extract unique B:## and G:## ## ## values
    b_set = set()
    g_set = set()
    for L in lines:
        i = L.find('B:')
        if i >= 0 and i + 5 <= len(L):
            b_set.add(L[i:i+5])  # 'B:##' actually 4 chars; use 5 to grab a space
        j = L.find('G:')
        if j >= 0 and j + 11 <= len(L):
            g_set.add(L[j:j+11])
    print('Unique B fields (music_num low): ' + repr(b_set))
    print('Unique G fields (dispLo / music_hi / dispBank): ' + repr(g_set))
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('shot -> ' + os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
