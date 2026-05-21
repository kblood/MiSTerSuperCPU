"""Verify $D27C-$D27F return spec values (00, 02, 00, F6) after the
SuperRAM-extent fix lands. Generates a small BASIC program that PEEKs
the four registers and PRINTs the results, deploys to MiSTer, captures
screen RAM via screenshot, and reports whether the read intercept fired.

Expected post-fix:
  D27C = 0
  D27D = 2
  D27E = 0
  D27F = 246

Pre-fix the values are VIC chip-mirror garbage (typically $FF for
unmapped VIC reads with C64 in standard I/O config).
"""
import os, time, paramiko

HOST,USER,PASS = '192.168.50.130','root','1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'peek_d27c')

# Tokenized BASIC PRG that prints PEEK(53884..53887) on a fresh line each
# Easier: we'll type it interactively via mtype.
PRG_LINES = [
    'PRINT PEEK(53884);PEEK(53885);PEEK(53886);PEEK(53887)',
]

def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')

    sftp = c.open_sftp()
    with sftp.open(CFG,'rb+') as f: f.seek(10); f.write(bytes([0x84]))
    sftp.close()

    print('reload core ...')
    run('echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)

    # Type: PRINT PEEK(...) <RETURN>
    keys = 'P R I N T SPACE P E E K LEFTPAREN 5 3 8 8 4 RIGHTPAREN SEMICOLON P E E K LEFTPAREN 5 3 8 8 5 RIGHTPAREN SEMICOLON P E E K LEFTPAREN 5 3 8 8 6 RIGHTPAREN SEMICOLON P E E K LEFTPAREN 5 3 8 8 7 RIGHTPAREN ENTER'
    print('typing PRINT PEEK(...)... ')
    run('python3 /tmp/mtype.py ' + keys, t=60)
    time.sleep(2)

    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp(); sftp.get(rp, os.path.join(OUT, 'shot.png')); sftp.close()
        print('screenshot saved to', os.path.join(OUT, 'shot.png'))
    c.close()

if __name__ == '__main__':
    main()
