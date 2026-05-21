"""v288: Doom full flow + peek $87:$E9C0..$EAD0 (where error dispatcher
saves args). After Doom prints "Bad music number -9" and halts, load
peek_e9c0.prg via MGL — SDRAM banks $01..$FF survive core reload, so
$87:$E9C8 should still hold music_num low byte.

If $E9C8/$E9C9 = $F7 $FF → music_num was -9 (16-bit signed = $FFF7).
$E9CA/$E9CB = $8A high byte saved.
"""
import os, time, paramiko

HOST,USER,PASS = '192.168.50.130','root','1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'loader.prg')
PEEK_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'peek_e9c0.prg')
LOADER_REMOTE = '/tmp/loader.prg'
PEEK_REMOTE = '/tmp/peek_e9c0.prg'
REU_REMOTE = '/media/fat/games/C64/doom.reu'
REU_MGL = '/tmp/load_doom_reu.mgl'
LOADER_MGL = '/tmp/load_doom_loader.mgl'
PEEK_MGL = '/tmp/load_peek_e9c0.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v288_peek_e9c0')

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    with open(LOADER_LOCAL,'rb') as f, sftp.open(LOADER_REMOTE,'wb') as r: r.write(f.read())
    with open(PEEK_LOCAL,'rb') as f, sftp.open(PEEK_REMOTE,'wb') as r: r.write(f.read())
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
    with sftp.open(CFG,'rb+') as f: f.seek(10); f.write(bytes([0x84]))
    sftp.close()

    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load doom.reu (16MB) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)
    print('load loader.prg (autorun) ...')
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')
    print('wait 180s for Doom to settle/halt ...')
    time.sleep(180)
    print('load peek_e9c0.prg (SDRAM persists) ...')
    run('echo load_core ' + PEEK_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(15)
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('shot -> ' + os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
