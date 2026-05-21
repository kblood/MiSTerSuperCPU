"""doom_v298_transition_zoom.py — capture 45s of continuous UART starting
at t=125s post-load, NO byte-count truncation. The bank-$20→$0F transition
happens in this window. Goal: catch the LAST frame in bank $20 and the
FIRST frame in bank $0F, identifying the dispatch site.
"""
import os, time, paramiko, re

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

    # Wait until t=125s, then capture 45s with HUGE buffer (300KB)
    print('  waiting until t=125s ...');
    sl = 125 - (time.time() - t0)
    if sl > 0: time.sleep(sl)
    print('  capturing 45s of UART (no byte truncation) ...')
    cmd = 'stty -F /dev/ttyS1 115200 raw -echo; timeout 45 cat /dev/ttyS1 2>&1 | head -c 300000'
    out = run(cmd, t=55)
    path = os.path.join(OUT, 'v298_transition_zoom.txt')
    with open(path, 'w', errors='replace') as f: f.write(out)
    nb = len(out.encode(errors='replace'))
    lines = [L for L in out.split('\n') if L.startswith('F:')]
    print(f'    {nb} bytes, {len(lines)} frames')

    # Analyze: find first frame where N bank is $0F, print surrounding context
    transition_idx = None
    for i, L in enumerate(lines):
        m = re.search(r'N:([0-9A-F]{6})', L)
        if m and m.group(1)[:2] == '0F':
            transition_idx = i
            break
    if transition_idx is None:
        print('  NO bank-$0F transition observed in this window')
    else:
        print(f'  *** Bank-$0F transition at frame index {transition_idx} ***')
        print('  --- 6 frames before transition ---')
        for L in lines[max(0,transition_idx-6):transition_idx]:
            print('    ' + L[:220])
        print('  --- TRANSITION frame ---')
        print('    ' + lines[transition_idx][:220])
        print('  --- 4 frames after ---')
        for L in lines[transition_idx+1:transition_idx+5]:
            print('    ' + L[:220])

    c.close()

if __name__ == '__main__':
    main()
