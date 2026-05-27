"""Deploy v356 archived RBF + run v3 CRT autoload probe.

v356 (md5 19839ee7) is the last known-good Doom-passing build. Validates
v3's BASIC-free direct-ML-entry mechanism without dragging in the
milestone-b SDRAM A10 bug.
"""
import paramiko, time, os, sys, hashlib, datetime

HOST, USER, PASS = '192.168.50.130', 'root', '1'
V356_LOCAL = 'C64_MiSTer/builds/C64_vanilla-cpu-swap_db149d6a92_20260519T045656Z_19839ee7-dirty.rbf'
CRT_LOCAL = 'crt/doom_autoload.crt'
MGL_LOCAL = 'tools/_doom_autoload_abs.mgl'
CRT_REMOTE = '/media/fat/games/C64/doom_autoload.crt'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload_abs.mgl'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG_REMOTE = '/media/fat/config/C64.cfg'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_autoload', 'v3_on_v356')


def run(c, cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def shot(c, sftp, dest_path):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png 2>/dev/null')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    rp = rp.strip()
    if not rp:
        print('  (no screenshot)')
        return None
    sftp.get(rp, dest_path)
    sha = hashlib.sha256(open(dest_path, 'rb').read()).hexdigest()[:10]
    print('  %s  sha=%s' % (os.path.basename(dest_path), sha))
    return sha


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    log_path = os.path.join(OUT_DIR, 'probe.log')
    log = open(log_path, 'w', encoding='utf-8')

    def say(*a):
        msg = ' '.join(str(x) for x in a)
        print(msg)
        log.write(msg + '\n'); log.flush()

    say('=== v3_on_v356_probe %s ===' % datetime.datetime.now().isoformat(timespec='seconds'))

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=10)
    c.get_transport().set_keepalive(20)

    cn, _ = run(c, 'cat /tmp/CORENAME 2>/dev/null')
    say('corename pre:', cn.strip() or '(empty)')
    if cn.strip() and cn.strip() not in ('C64', 'MENU'):
        say('!!! MiSTer held by other agent — aborting.')
        return 2

    # Deploy v356 RBF
    sftp = c.open_sftp()
    say('uploading v356 RBF as /media/fat/_Test/C64.rbf ...')
    sftp.put(V356_LOCAL, RBF_REMOTE)
    out, _ = run(c, 'md5sum %s' % RBF_REMOTE)
    say('rbf md5:', out.strip())

    say('uploading crt + mgl ...')
    sftp.put(CRT_LOCAL, CRT_REMOTE)
    sftp.put(MGL_LOCAL, MGL_REMOTE)
    out, _ = run(c, 'md5sum %s %s' % (CRT_REMOTE, MGL_REMOTE))
    say(out.strip())

    # Set SCPU + overlay (cfg byte 10 = 0x0C)
    run(c, "printf '\\x0c' | dd of=%s bs=1 count=1 seek=10 conv=notrunc 2>/dev/null" % CFG_REMOTE)

    # Load v356 core fresh
    say('load_core C64.rbf (v356) ...')
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % RBF_REMOTE)
    time.sleep(12)
    shot(c, sftp, os.path.join(OUT_DIR, '00_basic_ready.png'))

    # Fire MGL
    say('load MGL (REU + v3 CRT) ...')
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % MGL_REMOTE)

    checkpoints = [(20, 't020s'), (35, 't035s'), (50, 't050s'),
                   (70, 't070s'), (100, 't100s'), (150, 't150s'), (200, 't200s')]
    prev = 0
    for t, label in checkpoints:
        time.sleep(t - prev)
        prev = t
        shot(c, sftp, os.path.join(OUT_DIR, f'{label}.png'))

    # Final UART
    say('capturing UART (5 s) ...')
    out, _ = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1', t=10)
    with open(os.path.join(OUT_DIR, 'final_uart.txt'), 'w', encoding='utf-8', errors='replace') as f:
        f.write(out)
    say('uart lines:', out.count('\n'))

    sftp.close()
    c.close()
    log.close()
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
