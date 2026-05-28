#!/usr/bin/env python3
"""IEC LOAD-wedge probe (no build).

Sets CPU mode (t65|scpu), fires the lorenz autoload MGL (LOAD"*",8,1),
lets it run/wedge, then captures the debug UART and extracts the
IEC-relevant fields so we can tell write-side vs drive-side:

  PC: / J:    - CPU program counter + recent jump history
  PA:         - CIA2 PRA ($DD00 out latch: b5=DATA-o b4=CLK-o b3=ATN-o)
  DA:         - CIA2 DDRA (which $DD00 bits are driven; 0=hi-Z)
  M2: T2:     - CIA2 IMR + Timer-A CRA
  FS: DI: ... - bridge FSM probes
  DD=         - last $DD00 write value (overlay field)

Usage: python tools/iec_wedge_probe.py [t65|scpu] [--secs N]
"""
import sys, time, socket, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
MGL_AUTO = '/media/fat/_Test/lorenz_autoload.mgl'
DISK_PATH = '/media/fat/games/C64/lorenz_autoload.prg'  # reuse existing
PRG_REMOTE = '/media/fat/games/C64/lorenz_autoload.prg'
DISK_D64 = '/media/fat/games/C64/lorenz_disk1.d64'


def ssh():
    # Pre-connect a raw socket (sock=) to dodge an intermittent Windows Winsock
    # getaddrinfo race (errno 10109) in paramiko.connect(); retry transiently.
    last = None
    for _ in range(4):
        try:
            sock = socket.create_connection((HOST, 22), timeout=10)
            c = paramiko.SSHClient()
            c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            c.connect(HOST, username=USER, password=PASS, timeout=15, sock=sock)
            c.get_transport().set_keepalive(15)
            return c
        except Exception as e:
            last = e
            time.sleep(1)
    raise last


def run(c, cmd, timeout=30):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def core_mtime(c):
    out, _ = run(c, "stat -c %Y /tmp/CORENAME 2>/dev/null")
    try:
        return int(out.strip())
    except Exception:
        return 0


def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else 'scpu').lower()
    secs = 8
    if '--secs' in sys.argv:
        secs = int(sys.argv[sys.argv.index('--secs') + 1])
    cfg_val = 0x0c if mode == 'scpu' else 0x08

    c = ssh()
    # ownership guard
    cn, _ = run(c, 'cat /tmp/CORENAME 2>/dev/null')
    print('CORENAME=%r' % cn.strip())

    run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(cfg_val, CFG))
    got, _ = run(c, "dd if={} bs=1 count=1 skip=10 2>/dev/null | xxd -p".format(CFG))
    print('cfg byte10 -> 0x%02x (verified %s)' % (cfg_val, got.strip()))

    if '--turbo-off' in sys.argv:
        # status[47:46] = byte5 bits 7,6 -> clear both = Turbo mode Off (turbo_m="000" always)
        b5, _ = run(c, "dd if={} bs=1 count=1 skip=5 2>/dev/null | xxd -p".format(CFG))
        old = int(b5.strip(), 16)
        new = old & 0x3F
        run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=5 conv=notrunc 2>/dev/null".format(new, CFG))
        chk, _ = run(c, "dd if={} bs=1 count=1 skip=5 2>/dev/null | xxd -p".format(CFG))
        print('TURBO OFF: byte5 0x%02x -> 0x%02x (verified %s)' % (old, new, chk.strip()))

    pre = core_mtime(c)
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(RBF))
    dl = time.time() + 25
    while time.time() < dl:
        time.sleep(2)
        if core_mtime(c) != pre:
            break
    print('core reloaded; settle 8s')
    time.sleep(8)

    # autoload MGL (disk + auto-RUN PRG)
    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" path="{}"/>\n'
           '<file delay="8" type="f" index="1" path="{}"/>\n'
           '</mistergamedescription>\n').format(DISK_D64, PRG_REMOTE)
    sftp = c.open_sftp()
    with sftp.open(MGL_AUTO, 'w') as f:
        f.write(mgl)
    sftp.close()
    pre = core_mtime(c)
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(MGL_AUTO))
    print('autoload MGL fired; settle 22s for wedge')
    time.sleep(22)

    # capture UART
    run(c, 'stty -F /dev/ttyS1 115200 raw -echo')
    out, _ = run(c, 'timeout {} cat /dev/ttyS1'.format(secs), timeout=secs + 10)
    print('--- raw UART ({} s) ---'.format(secs))
    print(out[-4000:])
    c.close()


if __name__ == '__main__':
    main()
