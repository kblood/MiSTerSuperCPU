"""v342 IRQ-starvation fix test.

Sequence:
  1. load_core doom_reu_only.mgl -> populates REU SDRAM with doom.reu (~30-50s for 16MB)
  2. inject loader.prg via mbc load_rom
  3. send RUN<Enter> via mtype keys -> loader copies REU -> SuperRAM (~60s)
  4. send launcher POKE49152..58 + SYS49152
  5. screenshot + UART capture at t=30, 120, 240s
  6. save into tools/doom_full/ as v342_*

Cancel any other MGL/PRG activity before running.
"""
import os, time, paramiko, sys

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'
REU_MGL = '/media/fat/_Test/doom_reu_only.mgl'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def screenshot(c, name):
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, name))
        sftp.close()
        print('  screenshot saved:', name)


def capture_uart(c, name, seconds=5):
    out = run(c, 'stty -F /dev/ttyS1 115200 raw -echo; timeout %d cat /dev/ttyS1 2>&1' % seconds, t=seconds + 5)
    p = os.path.join(OUT, name)
    with open(p, 'w', errors='replace') as f:
        f.write(out)
    nlines = sum(1 for _ in out.split('\n') if _.strip())
    print('  UART %d lines -> %s' % (nlines, name))
    return out


def type_line(c, text, delay_after=2):
    """Type a line via mtype.py followed by Enter.  ONE invocation per line
    because mtype.py has a 6-second device-setup delay each call (it creates
    a fresh uinput device and waits for MiSTer to attach the kbd handler).
    """
    quoted = text.replace("'", "'\\''")
    cmd = "python3 /tmp/mtype.py '%s' enter" % quoted
    run(c, cmd, t=30)
    time.sleep(delay_after)


def send_keys(c, keys, delay=0.5):
    """Legacy single-call wrapper (kept for compatibility).  Use type_line
    when sending text + Enter.
    """
    quoted = keys.replace("'", "'\\''")
    run(c, "python3 /tmp/mtype.py '%s'" % quoted, t=20)
    time.sleep(delay)


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    print('Connected.')

    # Cooperation gate: bail if non-C64 core is loaded.
    cn = run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    if cn and cn != 'C64':
        print('ABORT: /tmp/CORENAME = %r (not C64). Other agent owns MiSTer.' % cn)
        c.close()
        return 2
    run(c, "echo \"agent=c64 task=doom-v342-irq-fix since=$(date -Iseconds)\" > /tmp/mister_session.lock")
    print('Lock written, CORENAME=%r' % cn)

    # Ensure mtype.py is uploaded (CLAUDE.md says it must be at /tmp/mtype.py)
    local_mtype = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mtype.py')
    if os.path.exists(local_mtype):
        sftp = c.open_sftp()
        sftp.put(local_mtype, '/tmp/mtype.py')
        sftp.close()
        print('mtype.py uploaded.')

    # 1) Load doom.reu via MGL
    print('Step 1: load doom_reu_only.mgl to populate REU SDRAM ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    print('  waiting 50s for 16MB REU upload ...')
    time.sleep(50)
    screenshot(c, 'v342_after_reu.png')

    # 2) Inject loader.prg via mbc load_rom (mbc auto-detects PRG)
    print('Step 2: inject loader.prg via mbc ...')
    run(c, 'mbc load_rom /media/fat/games/C64/loader.prg C64 2>&1', t=20)
    time.sleep(5)
    screenshot(c, 'v342_after_prg_inject.png')

    # 3) Send RUN+Enter as ONE mtype.py invocation (avoids 6s device-setup penalty per call).
    print('Step 3: type RUN<Enter> to start loader ...')
    type_line(c, 'RUN', delay_after=3)
    print('  loader running, wait 60s for 16MB REU->SuperRAM copy ...')
    time.sleep(60)
    screenshot(c, 'v342_after_loader_done.png')

    # 4) Send launcher POKE+SYS49152 sequence — one mtype.py call per line.
    print('Step 4: send launcher POKE+SYS49152 ...')
    launcher_lines = [
        'POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92',
        'POKE49156,0:POKE49157,0:POKE49158,32',
        'SYS49152',
    ]
    for ln in launcher_lines:
        type_line(c, ln, delay_after=2)
    time.sleep(3)
    screenshot(c, 'v342_after_launcher.png')

    # 5) Capture at t=30, 120, 240s from launcher SYS
    t0 = time.time()
    for label, t_target, ushot in [('30s', 30, True), ('120s', 120, True), ('240s', 240, True)]:
        wait = t_target - (time.time() - t0)
        if wait > 0:
            print('  sleep %.1fs to reach t=%s ...' % (wait, label))
            time.sleep(wait)
        capture_uart(c, 'v342_uart_' + label + '.txt', seconds=5)
        if ushot:
            screenshot(c, 'v342_t' + label + '.png')

    # 6) Long capture: keep UART for 240s into a single file from this point
    print('Final 240s UART capture for analysis ...')
    capture_uart(c, 'v342_uart.txt', seconds=240)

    c.close()
    print('Done.')


if __name__ == '__main__':
    sys.exit(main())
