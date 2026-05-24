#!/usr/bin/env python3
"""Run scpu_speed_bench.prg on v8 via MGL autoload (no mtype).

Loads the PRG via `<file type="f" index="1">` so MiSTer's start_strk
synthesizes RUN. Sidesteps the mtype timing race at turbo. Captures
the bench's $D0B8 STATUS display + 4-phase counts.
"""
import os, time, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
LOCAL_PRG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'test_cart', 'out', 'scpu_speed_bench.prg')
REMOTE_PRG = '/media/fat/games/C64/scpu_speed_bench.prg'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'scpu_speed_bench_mgl')


def shot(c, name):
    c.exec_command('echo screenshot > /dev/MiSTer_cmd', timeout=5)
    time.sleep(2.5)
    _, o, _ = c.exec_command(
        'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1',
        timeout=8)
    remote = o.read().decode().strip()
    if not remote:
        return None
    sftp = c.open_sftp()
    local = os.path.join(OUT, name + '.png')
    sftp.get(remote, local)
    sftp.close()
    print(f'  shot -> {name}.png')
    return local


def main():
    os.makedirs(OUT, exist_ok=True)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(15)

    sftp = c.open_sftp()
    sftp.put(LOCAL_PRG, REMOTE_PRG)

    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           f'<file delay="3" type="f" index="1" path="{REMOTE_PRG}"/>\n'
           '</mistergamedescription>\n')
    with sftp.open('/tmp/scpu_bench.mgl', 'w') as f:
        f.write(mgl)
    sftp.close()
    print(f'PRG ({os.path.getsize(LOCAL_PRG)} B) + MGL ready')

    # SCPU mode
    _, o, _ = c.exec_command(
        "printf '\\x0c' | dd of=/media/fat/config/C64.cfg "
        "bs=1 count=1 seek=10 conv=notrunc 2>/dev/null", timeout=5)
    o.read()

    print('Loading via MGL...')
    c.exec_command('echo load_core /tmp/scpu_bench.mgl > /dev/MiSTer_cmd',
                   timeout=5)
    time.sleep(20)  # core load + delay=3 PRG load + RUN + bench runs

    shot(c, 't20s')
    time.sleep(5)
    shot(c, 't25s')
    time.sleep(5)
    shot(c, 't30s')

    c.close()
    print(f'\nOutputs in {OUT}')


if __name__ == '__main__':
    main()
