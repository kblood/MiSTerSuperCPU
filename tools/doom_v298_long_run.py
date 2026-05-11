"""doom_v298_long_run.py — load doom.reu + loader, then capture UART
for 5 minutes continuously. Check if Doom ever escapes bank $0F BRK-march
and reaches VIC bitmap config (D1 changes from $9B to something with bit 5 set).
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
    print('load doom.reu (16MB, 50s) ...')
    run('echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd'); time.sleep(50)
    print('load loader.prg (autorun) ...')
    t0 = time.time()
    run('echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Single 270s capture starting at t=30s. Saves ~150KB of UART.
    print('  waiting 30s for loader to start ...'); time.sleep(30)
    print('  capturing 270s of UART (4.5 min) ...')
    cmd = f'stty -F /dev/ttyS1 115200 raw -echo; timeout 270 cat /dev/ttyS1 2>&1 | head -c 200000'
    out = run(cmd, t=280)
    path = os.path.join(OUT, 'v298_long_270s.txt')
    with open(path, 'w', errors='replace') as f: f.write(out)
    nb = len(out.encode(errors='replace'))
    lines = [L for L in out.split('\n') if L.startswith('F:')]
    print(f'    {nb} bytes, {len(lines)} frames')

    # Quick analysis: check D1 distinct values, N bank distribution
    d1_vals = set()
    n_banks = {}
    pc_banks = {}
    wp_vals = set()
    last_real_pc = None
    for L in lines:
        m = re.search(r'D1:([0-9A-F]{2})', L);   d1_vals.add(m.group(1)) if m else None
        m = re.search(r'N:([0-9A-F]{6})', L)
        if m: n_banks[m.group(1)[:2]] = n_banks.get(m.group(1)[:2], 0) + 1
        m = re.search(r'PC:([0-9A-F]{6})', L)
        if m:
            pb = m.group(1)[:2]; pc_banks[pb] = pc_banks.get(pb, 0) + 1
            if pb not in ('00','0F'): last_real_pc = m.group(1)
        m = re.search(r'WP:([0-9A-F]{6})', L)
        if m: wp_vals.add(m.group(1))
    print(f'  D1 distinct: {sorted(d1_vals)}')
    print(f'  N bank histogram: {sorted(n_banks.items())}')
    print(f'  PC bank histogram (sorted): {sorted(pc_banks.items())[:8]}')
    print(f'  WP distinct: {len(wp_vals)} (sample: {sorted(wp_vals)[:5]})')
    print(f'  last_real_pc (not bank 00/0F): {last_real_pc}')

    # Screenshot at end
    run('rm -f /media/fat/screenshots/C64/*.png 2>/dev/null')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'shot_v298_long_final.png'))
        sftp.close()
        print('screenshot saved')
    c.close()

if __name__ == '__main__':
    main()
