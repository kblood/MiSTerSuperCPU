"""Single-PRG MGL autoload probe for Doom on the SuperCPU core.

doom_loader.prg is self-contained — it does both the REU FETCH chain
(transferring Doom from REU SDRAM into SuperRAM) and the final
XCE + JML $20:0000 that launches the game. Loaded via MGL with REU
+ PRG; MiSTer's start_strk synthesizes R-U-N + RETURN after the PRG
lands at $0801, BASIC parses RUN, SYS 2061 dispatches into the
loader's inner ML, and ~90-180 s later the Doom menu is up.

Validated on v356 RBF (md5 19839ee7) 2026-05-27: full Doom engine
init + id Software credits + main menu reached unattended.
"""
import paramiko, time, os, sys, hashlib, datetime, socket

HOST, USER, PASS = '192.168.50.130', 'root', '1'
MGL_LOCAL = 'tools/_doom_autoload.mgl'
LOADER_LOCAL = 'tools/doom_loader.prg'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload.mgl'
LOADER_REMOTE = '/media/fat/games/C64/doom_loader.prg'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG_REMOTE = '/media/fat/config/C64.cfg'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_autoload', 'single_prg')


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
        return None
    sftp.get(rp, dest_path)
    sha = hashlib.sha256(open(dest_path, 'rb').read()).hexdigest()[:10]
    print('  %s  sha=%s' % (os.path.basename(dest_path), sha))
    return sha


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    # Winsock getaddrinfo race workaround: pre-connect a raw socket, retry.
    last = None
    for attempt in range(4):
        try:
            sk = socket.create_connection((HOST, 22), timeout=10)
            c.connect(HOST, username=USER, password=PASS, timeout=10, sock=sk)
            last = None
            break
        except Exception as ex:
            last = ex
            time.sleep(1.5)
    if last is not None:
        raise last
    c.get_transport().set_keepalive(20)

    out, _ = run(c, 'md5sum %s' % RBF_REMOTE)
    print('rbf:', out.strip())

    sftp = c.open_sftp()
    sftp.put(MGL_LOCAL, MGL_REMOTE)
    sftp.put(LOADER_LOCAL, LOADER_REMOTE)

    # SCPU + overlay
    run(c, "printf '\\x0c' | dd of=%s bs=1 count=1 seek=10 conv=notrunc 2>/dev/null" % CFG_REMOTE)

    # Reload core fresh so REU SDRAM starts clean
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % RBF_REMOTE)
    time.sleep(12)
    shot(c, sftp, os.path.join(OUT_DIR, '00_basic_ready.png'))

    print('load MGL ...')
    run(c, 'echo load_core %s > /dev/MiSTer_cmd' % MGL_REMOTE)

    # Capture at progressively later checkpoints; the launcher fires at
    # delay=120 (12s after stage1 PRG load completes).
    schedule = [(15, 't015'), (30, 't030'), (45, 't045'),
                (60, 't060'), (90, 't090'), (120, 't120'),
                (150, 't150'), (180, 't180'), (220, 't220')]
    prev = 0
    for t, label in schedule:
        time.sleep(t - prev); prev = t
        shot(c, sftp, os.path.join(OUT_DIR, f'{label}.png'))

    out, _ = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1', t=10)
    with open(os.path.join(OUT_DIR, 'final_uart.txt'), 'w', encoding='utf-8', errors='replace') as f:
        f.write(out)
    print('uart lines:', out.count('\n'))

    sftp.close(); c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
