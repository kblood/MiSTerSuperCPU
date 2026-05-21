#!/usr/bin/env python3
"""Probe B (full-loader): capture HW $00:$00FC writer-PC ring for Doom.

After v293 RTL repurpose (wr02_* fields -> $00:$00FC writes), the UART
"V:## ## ## ##  YX:####  WP:######  CG:####  CY:####" segment reflects:
  V  = ring of last 4 values written to $00:$00FC (oldest..newest)
  YX = Y/X regs at most recent write
  WP = PBR:PC of most recent write
  CG = count of writes where new value != previous (changes)
  CY = total writes

Two-step MGL pattern (per tools/doom_full_run.py):
  1. doom.reu via MGL  -> populates REU SDRAM (~50s for 16MB)
  2. loader.prg via MGL -> BASIC autoruns SYS 2061 -> covert-bitops loader
     does the REU FETCH + long-store transfer to SuperRAM banks $20+.
     Loader auto-jumps to Doom on completion. Doom halts at "Bad music
     number -9" trap ($2C:$A95C reached via JML [$0074]).

Expected from v292 baseline (loader.prg, 88x $5C writes from $00:$077D):
  - CY ~= 88 + (small KERNAL count); WP near $00:$077D; V ring all $5C;
    CG = 1 -> hardware only writes loader's $5C; Doom never overwrites.
    Bug is "missing Doom dispatcher install".
  - CY > ~90 OR CG > 1 OR V shows non-$5C bytes -> hardware DOES write
    other values. WP/V/CG identify which writer fires.
"""
import os, time, paramiko, base64

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF = '/media/fat/_Test/C64.rbf'
CFG = '/media/fat/config/C64.cfg'

LOADER_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            '..', 'loader.prg')
LOADER_REMOTE = '/tmp/loader.prg'
REU_REMOTE = '/media/fat/games/C64/doom.reu'
REU_MGL = '/tmp/load_doom_reu.mgl'
LOADER_MGL = '/tmp/load_doom_loader.mgl'

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'doom_probe_fc_writer')


def run(c, cmd, t=20):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace')


def upload(c, local, remote):
    with open(local, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    run(c, 'rm -f {0}.b64 {0}'.format(remote))
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, remote))
    run(c, 'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(remote))


def write_mgls(c):
    reu_mgl = ('<mistergamedescription>\n'
               '<rbf>_Test/C64</rbf>\n'
               '<file delay="3" type="f" index="1" path="' +
               REU_REMOTE + '"/>\n'
               '</mistergamedescription>\n')
    loader_mgl = ('<mistergamedescription>\n'
                  '<rbf>_Test/C64</rbf>\n'
                  '<file delay="3" type="f" index="1" path="' +
                  LOADER_REMOTE + '"/>\n'
                  '</mistergamedescription>\n')
    sftp = c.open_sftp()
    with sftp.open(REU_MGL, 'w') as f:
        f.write(reu_mgl)
    with sftp.open(LOADER_MGL, 'w') as f:
        f.write(loader_mgl)
    sftp.close()


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)

    print('uploading loader.prg ...')
    upload(c, LOADER_LOCAL, LOADER_REMOTE)
    print('writing MGLs ...')
    write_mgls(c)

    # cfg byte 10: SCPU(0x04) + Debug UART(0x80) = 0x84
    sftp = c.open_sftp()
    with sftp.open(CFG, 'rb+') as f:
        f.seek(10)
        f.write(bytes([0x84]))
    sftp.close()
    print('cfg byte 10 = 0x84')

    print('reloading core ...')
    run(c, 'echo load_core ' + RBF + ' > /dev/MiSTer_cmd')
    time.sleep(8)

    print('load doom.reu (16MB transfer, wait 50s) ...')
    run(c, 'echo load_core ' + REU_MGL + ' > /dev/MiSTer_cmd')
    time.sleep(50)

    print('load loader.prg (autorun BASIC SYS 2061) ...')
    run(c, 'echo load_core ' + LOADER_MGL + ' > /dev/MiSTer_cmd')

    # Loader runs through chunk skip / inner long-store for ~3-4 minutes
    # to transfer the full 16MB REU image into SuperRAM banks $20+, then
    # jumps to Doom which prints the music_num=-9 error and halts.
    print('waiting 240s for loader to finish + Doom halt ...')
    time.sleep(240)

    print('capturing UART for 30s ...')
    out = run(
        c,
        'stty -F /dev/ttyS1 115200 raw -echo; '
        'timeout 30 cat /dev/ttyS1 2>&1 | head -c 200000',
        t=40,
    )
    uart_path = os.path.join(OUT, 'uart_post_halt_fullloader.txt')
    with open(uart_path, 'w', errors='replace') as f:
        f.write(out)
    print('UART -> ' + uart_path)
    print('  bytes captured: {}'.format(len(out)))

    # Capture screen too
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    rp = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if rp:
        sftp = c.open_sftp()
        sftp.get(rp, os.path.join(OUT, 'halt_screen_fullloader.png'))
        sftp.close()
        print('screen -> halt_screen_fullloader.png')

    # Parse last well-formed UART line
    lines = [ln for ln in out.split('\n') if 'WP:' in ln and 'CY:' in ln]
    print('  well-formed UART lines: {}'.format(len(lines)))

    if lines:
        last = lines[-1].strip()
        print('LAST LINE:', last[:280])

        def _get(line, key):
            i = line.find(key)
            if i < 0:
                return None
            j = i + len(key)
            k = j
            while k < len(line) and line[k] not in ' ':
                k += 1
            return line[j:k]

        wp = _get(last, 'WP:')
        vi = last.find('V:')
        v_segment = last[vi:vi + 13] if vi >= 0 else None
        cg = _get(last, 'CG:')
        cy = _get(last, 'CY:')
        yx = _get(last, 'YX:')

        print()
        print('Parsed fields:')
        print('  WP =', wp, '  V =', v_segment, '  YX =', yx,
              '  CG =', cg, '  CY =', cy)

        if cy:
            try:
                cy_dec = int(cy, 16)
                cg_dec = int(cg, 16) if cg else 0
                print('  CY={} writes total; CG={} value-changes'.format(
                    cy_dec, cg_dec))
            except ValueError:
                pass
    else:
        print('NO well-formed UART lines - check uart_post_halt_fullloader.txt')

    c.close()


if __name__ == '__main__':
    main()
