"""v347 B1/B3 probe test — deploy + run doom + extract B1/B3 field across
UART captures.

B1:## = per-frame saturating count of CPU SDRAM writes to bank-0 SDRAM
        $4000-$5FFF (Doom bitmap page A).
B3:## = same for $C000-$DFFF (Doom bitmap page B).

  Both $00 across 240s → Doom never reaches bitmap renderer.
  B1>0 / B3>0          → Doom IS writing bitmap; bug elsewhere.

Reuses the v342 test flow.
"""
import os, re, time, sys, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = 'C64_MiSTer/output_files/C64.rbf'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full')


def check_ownership(c):
    _, o, _ = c.exec_command('cat /tmp/CORENAME 2>/dev/null')
    cn = o.read().decode().strip()
    if cn and cn not in ('C64', 'MENU'):
        print('ABORT: /tmp/CORENAME = %r (not C64).' % cn)
        return False
    return True


def deploy(c):
    sftp = c.open_sftp()
    sftp.put(RBF_LOCAL, RBF_REMOTE)
    _, o, _ = c.exec_command('md5sum ' + RBF_REMOTE)
    print('Deployed: ' + o.read().decode().strip())
    sftp.close()


def parse_field(uart_path, field):
    """Extract <field>:## values across UART file."""
    out = []
    if not os.path.exists(uart_path):
        return out
    pat = re.compile(r'%s:(\w{2})' % field)
    with open(uart_path, 'r', errors='replace') as f:
        for line in f:
            m = pat.search(line)
            if m:
                out.append(int(m.group(1), 16))
    return out


def summarize(label, uart_path):
    for fld in ['B1', 'B3', 'B6']:
        vals = parse_field(uart_path, fld)
        if not vals:
            print('  %s/%s: not parsed' % (label, fld))
            continue
        nz = sum(1 for v in vals if v != 0)
        print('  %s/%s: %d samples, nz=%d/%d, first/last/peak=$%02X/$%02X/$%02X' % (
            label, fld, len(vals), nz, len(vals), vals[0], vals[-1], max(vals)))


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    print('Connected.')
    if not check_ownership(c):
        return 2
    deploy(c)
    c.close()

    rc = os.system('python tools/doom_v342_test.py')
    if rc != 0:
        print('doom_v342_test.py exit %d' % rc)
        return rc

    print('\nv347 B1/B3 summary across UART captures:')
    for label in ['30s', '120s', '240s']:
        summarize(label, os.path.join(OUT, 'v342_uart_' + label + '.txt'))
    summarize('full-240', os.path.join(OUT, 'v342_uart.txt'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
