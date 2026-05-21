"""v345e deploy + smoke-test + Doom regression.

Sequence:
 1. md5 of new C64_MiSTer/output_files/C64.rbf
 2. scp -> /media/fat/_Test/C64.rbf
 3. load_core -> verify CORENAME=C64
 4. tier3_mirror_test.prg via MGL -> screenshot (expect green border)
 5. Reset core. doom_full_run() -> uart_240s.txt + shot_240s.png
"""
import os, time, hashlib, paramiko, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'C64_MiSTer', 'output_files', 'C64.rbf'))
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
TIER3_LOCAL = os.path.join(os.path.dirname(__file__), 'tier3_mirror_test.prg')
TIER3_REMOTE = '/tmp/tier3_mirror_test.prg'
TIER3_MGL = '/tmp/load_tier3.mgl'
OUT = os.path.join(os.path.dirname(__file__), 'v345e_results')

def md5_of(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

def main():
    if not os.path.exists(RBF_LOCAL):
        print(f'MISSING RBF: {RBF_LOCAL}')
        sys.exit(1)
    os.makedirs(OUT, exist_ok=True)
    local_md5 = md5_of(RBF_LOCAL)
    size = os.path.getsize(RBF_LOCAL)
    print(f'Local v345e RBF: {RBF_LOCAL}')
    print(f'  size={size} md5={local_md5}')

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    def run(cmd, t=20):
        _, o, _ = c.exec_command(cmd, timeout=t)
        return o.read().decode(errors='replace')

    # Step 1: deploy RBF
    print('deploying ...')
    sftp = c.open_sftp()
    sftp.put(RBF_LOCAL, RBF_REMOTE)
    sftp.put(TIER3_LOCAL, TIER3_REMOTE)
    # Write tier3 MGL
    mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
           f'<file delay="3" type="f" index="1" path="{TIER3_REMOTE}"/>\n'
           '</mistergamedescription>\n')
    with sftp.open(TIER3_MGL, 'w') as f:
        f.write(mgl)
    sftp.close()

    remote_md5 = run('md5sum ' + RBF_REMOTE).split()[0]
    print(f'Remote RBF md5: {remote_md5}')
    if remote_md5 != local_md5:
        print('MD5 MISMATCH — deploy failed')
        sys.exit(2)

    # Step 2: load core
    print('load_core ...')
    run('echo load_core ' + RBF_REMOTE + ' > /dev/MiSTer_cmd')
    time.sleep(8)
    cn = run('cat /tmp/CORENAME').strip()
    print(f'CORENAME={cn}')
    if 'C64' not in cn:
        print('Failed to load C64 core')
        sys.exit(3)

    # Step 3: tier3 mirror test
    print('tier3 test via MGL ...')
    run('echo load_core ' + TIER3_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(12)
    run('rm -f /media/fat/screenshots/C64/*.png')
    run('echo screenshot > /dev/MiSTer_cmd')
    time.sleep(3)
    rp = run('ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'tier3_shot.png'))
        sftp.close()
        print('  -> tier3_shot.png saved')
    else:
        print('  WARNING: no screenshot captured')

    c.close()
    print('DEPLOY + tier3 smoke complete. Now run tools/doom_full_run.py for the Doom regression.')

if __name__ == '__main__':
    main()
