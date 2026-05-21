"""v292 + patched doom.reu — does Doom continue past the music_num trap?

Uses doom_patched_a95c.reu (trap at $2C:$A95C redirected to $2C:$860E).
Watches for: (a) different halt PC, (b) screen content change, (c) UART
G-field showing different writer of $FC=$5C.

Same v292 RBF on hardware (latch on $FC stores with value $5C).
"""
import os, time, paramiko

HOST,USER,PASS = '192.168.50.130','root','1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
PATCHED_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'doom_patched_a95c.reu')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/doom_patched_a95c.reu'
REU_MGL = '/tmp/load_doom_patched_reu.mgl'
LOADER_MGL = '/tmp/load_doom_loader.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v292_doom_patched')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    print('upload loader.prg ...')
    with open(LOADER_LOCAL,'rb') as f, sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
    print('upload doom_patched_a95c.reu (16MB; ~30s) ...')
    with open(PATCHED_LOCAL,'rb') as f, sftp.open(REU_REMOTE,'wb') as r:
        # Chunked write to avoid SFTP timeouts on big files
        while True:
            chunk = f.read(0x40000)
            if not chunk: break
            r.write(chunk)
    print('  done')
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
    print('load patched doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 180s ...')
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
    g_set = set(); b_set = set(); pc_set = set(); j_set = set()
    for L in lines:
        for tag, store in [('G:',g_set),('B:',b_set),('PC:',pc_set),('J:',j_set)]:
            i = L.find(tag)
            if i >= 0:
                if tag == 'PC:':
                    store.add(L[i:i+9])
                elif tag == 'J:':
                    store.add(L[i:i+24])
                elif tag == 'G:':
                    store.add(L[i:i+11])
                else:
                    store.add(L[i:i+5])
    print('\nUnique PC: ' + repr(pc_set)[:240])
    print('Unique G:  ' + repr(g_set)[:240])
    print('Unique B:  ' + repr(b_set)[:240])
    print('Unique J:  ' + repr(j_set)[:240])
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('shot -> ' + os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
