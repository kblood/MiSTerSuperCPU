"""v346 B6 probe test — deploy + run doom + extract B6 field across UART
captures.

B6:## is the per-frame sticky OR of vicDi (the byte VIC reads from RAM at
each fetch slot). Latched once per vsync rising edge.

  B6=$00 across 240s → VIC reads only zero bytes → bitmap region in SDRAM
                       is empty → CPU writes to bank-1 aren't reaching the
                       SDRAM bytes VIC fetches from.

  B6 != $00          → VIC sees data; black has non-memory cause (VIC
                       config, color RAM, $D020/$D021, sprite occlusion).

Reuses the v342 test flow so the comparison is apples-to-apples.
"""
import os, re, time, sys, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = 'C64_MiSTer/output_files/C64.rbf'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_full')


def check_ownership(c):
    _, o, _ = c.exec_command('cat /tmp/CORENAME 2>/dev/null')
    cn = o.read().decode().strip()
    # MENU / empty / C64 are all OK to proceed. Bail only if another core
    # (CD32, Minimig, SimCity-CD32MVP, ...) is loaded.
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


def parse_b6(uart_path):
    """Extract B6:## values across UART file. Returns list of integers."""
    out = []
    if not os.path.exists(uart_path):
        return out
    with open(uart_path, 'r', errors='replace') as f:
        for line in f:
            m = re.search(r'B6:(\w{2})', line)
            if m:
                out.append(int(m.group(1), 16))
    return out


def summarize_b6(label, uart_path):
    vals = parse_b6(uart_path)
    if not vals:
        print('  %s: no B6 values parsed (%s)' % (label, uart_path))
        return
    or_all = 0
    for v in vals:
        or_all |= v
    nonzero = sum(1 for v in vals if v != 0)
    print('  %s: %d samples, sticky-OR=$%02X, nonzero/total=%d/%d, first/last/peak=$%02X/$%02X/$%02X' % (
        label, len(vals), or_all, nonzero, len(vals),
        vals[0], vals[-1], max(vals)))


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    print('Connected.')
    if not check_ownership(c):
        return 2
    deploy(c)
    c.close()

    # Run the canonical v342 test flow (same loader + launcher + UART captures)
    rc = os.system('python3 tools/doom_v342_test.py')
    if rc != 0:
        print('doom_v342_test.py exit %d' % rc)
        return rc

    # Summarize B6 across all UART captures
    print('\nB6 field summary across all v342 test UART captures:')
    for label in ['30s', '120s', '240s']:
        summarize_b6(label, os.path.join(OUT, 'v342_uart_' + label + '.txt'))
    summarize_b6('full-240', os.path.join(OUT, 'v342_uart.txt'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
