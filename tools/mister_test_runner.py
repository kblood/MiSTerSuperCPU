"""Generic MiSTer test runner — SFTP-writes cfg byte 10 (so 0x84 actually
sticks: SCPU on + UART), uploads PRG, builds MGL, reloads core, captures UART,
parses G/B latch, takes screenshot.

Replaces the buggy printf-via-paramiko approach in earlier runners.

Usage: python -m tools.mister_test_runner test_long_store_only
       python tools/mister_test_runner.py test_long_store_only
"""
import os, sys, time, paramiko, base64, re
from collections import Counter

HOST,USER,PASS = '192.168.50.130','root','1'
RBF='/media/fat/_Test/C64.rbf'
CFG='/media/fat/config/C64.cfg'

def run_test(prg_basename, cfg_byte10=0x84, settle_s=15, capture_s=5):
    here = os.path.dirname(os.path.abspath(__file__))
    PRG_LOCAL = os.path.join(here, prg_basename + '.prg')
    PRG_REMOTE = '/tmp/' + prg_basename + '.prg'
    PRG_MGL = '/tmp/load_' + prg_basename + '.mgl'
    OUT = os.path.join(here, prg_basename + '_run')
    os.makedirs(OUT, exist_ok=True)

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)

    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t)
        return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    with open(PRG_LOCAL, 'rb') as f:
        prg_data = f.read()
    with sftp.open(PRG_REMOTE, 'wb') as f:
        f.write(prg_data)
    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           '<file delay="3" type="f" index="1" path="' + PRG_REMOTE + '"/>\n'
           '</mistergamedescription>\n')
    with sftp.open(PRG_MGL, 'w') as f:
        f.write(mgl)
    with sftp.open(CFG, 'rb+') as f:
        f.seek(10)
        f.write(bytes([cfg_byte10]))
    sftp.close()

    # Verify cfg byte 10
    cfg_dump = run('xxd /media/fat/config/C64.cfg | head -1')
    print('cfg:', cfg_dump.strip())
    print('reload core ...'); run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd'); time.sleep(8)
    print('load PRG ...'); run('echo load_core ' + PRG_MGL + ' > /dev/MiSTer_cmd'); time.sleep(settle_s)
    print('capture UART (' + str(capture_s) + 's) ...')
    out = run('stty -F /dev/ttyS1 115200 raw -echo; timeout ' + str(capture_s) + ' cat /dev/ttyS1 2>&1', t=capture_s+5)
    with open(os.path.join(OUT, 'uart.txt'),'w',errors='replace') as f: f.write(out)
    g_re = re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
    b_re = re.compile(r'\bB:([0-9A-Fa-f]{2})')
    pc_re = re.compile(r'PC:([0-9A-Fa-f]{6})')
    gv = g_re.findall(out); bv = b_re.findall(out); pcv = pc_re.findall(out)
    print('Total G samples:', len(gv), 'B:', len(bv), 'PC:', len(pcv))
    if gv:
        last = gv[-1]
        print('  bank $00:$6C00 = $' + last[0])
        print('  bank $2A:$6C00 = $' + last[1] + '  <<<<<')
        print('  bank $00:$6C03 = $' + last[2])
        cv = Counter(g[1] for g in gv)
        print('  bank $2A:$6C00 hist:', cv.most_common(5))
    if bv:
        print('  bank $2A:$6C03 = $' + bv[-1])
        cv = Counter(bv); print('  hist:', cv.most_common(5))
    if pcv:
        cv = Counter(pcv); print('  PC hist:', cv.most_common(3))
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT,'border.png')); sftp.close()
        print('saved border.png')
    c.close()
    return out

if __name__ == '__main__':
    name = sys.argv[1] if len(sys.argv) > 1 else 'test_long_store_only'
    run_test(name)
