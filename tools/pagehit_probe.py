"""iter-29 page-hit-rate probe.

Deploys the current _Test/C64.rbf, autoloads Doom (reusing the
doom_autoload MGL + loader), waits for the engine/menu, then captures a
sustained UART window and parses the new PH:/PW: fields emitted by the
page-hit-rate observer (fpga64_sid_iec.vhd, repurposes the dead HR/HW slot).

PH = page-HITs per last 256 CPU SDRAM accesses (0..FF; PH/2.56 = % row-locality
     of the CPU's SDRAM access stream, single-global-open-row model).
PW = window-completion counter (must advance => observer is live).

Decision rule (project_pagemode_decision_rule_corrected): HIGH PH => page-mode
SDRAM is a big win (pursue Lever 1); PH < ~45% (0x73) => page-mode is slower,
drop it. Break-even H ~= 45%.

Usage:
  python tools/pagehit_probe.py            # load Doom, wait ~180s, sample 30s
  python tools/pagehit_probe.py --warm N    # seconds to wait before sampling
  python tools/pagehit_probe.py --sample N  # seconds of UART to capture
  python tools/pagehit_probe.py --keys      # after warm, send fire/return to
                                            # try to enter gameplay, then sample
"""
import paramiko, time, os, sys, hashlib, socket, re, argparse, statistics

HOST, USER, PASS = '192.168.50.130', 'root', '1'
MGL_LOCAL = 'tools/_doom_autoload.mgl'
LOADER_LOCAL = 'tools/doom_loader.prg'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload.mgl'
LOADER_REMOTE = '/media/fat/games/C64/doom_loader.prg'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG_REMOTE = '/media/fat/config/C64.cfg'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_autoload', 'pagehit')

PH_RE = re.compile(r'PH:([0-9A-Fa-f]{2})')
PW_RE = re.compile(r'PW:([0-9A-Fa-f]{2})')
PC_RE = re.compile(r'PC:([0-9A-Fa-f]{6})')


def run(c, cmd, t=20):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def connect():
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    last = None
    for _ in range(4):
        try:
            sk = socket.create_connection((HOST, 22), timeout=10)
            c.connect(HOST, username=USER, password=PASS, timeout=10, sock=sk)
            last = None; break
        except Exception as ex:
            last = ex; time.sleep(1.5)
    if last is not None:
        raise last
    c.get_transport().set_keepalive(20)
    return c


def capture_uart(c, secs, path):
    cmd = ('stty -F /dev/ttyS1 115200 raw -echo; timeout %d cat /dev/ttyS1 2>&1' % secs)
    out, _ = run(c, cmd, t=secs + 10)
    with open(path, 'w', encoding='utf-8', errors='replace') as f:
        f.write(out)
    return out


def analyze(out):
    ph = [int(m, 16) for m in PH_RE.findall(out)]
    pw = [int(m, 16) for m in PW_RE.findall(out)]
    pcs = PC_RE.findall(out)
    print('  UART lines: %d  PH samples: %d  PW samples: %d' % (out.count('\n'), len(ph), len(pw)))
    if pw:
        print('  PW (window-completion): first=%02X last=%02X  advanced=%s'
              % (pw[0], pw[-1], 'YES (observer live)' if pw[-1] != pw[0] else 'NO (frozen!)'))
    if ph:
        avg = statistics.mean(ph)
        print('  PH raw: min=%02X max=%02X avg=%.1f  (n=%d)' % (min(ph), max(ph), avg, len(ph)))
        print('  Page-hit rate: min=%.1f%%  max=%.1f%%  avg=%.1f%%'
              % (min(ph) / 2.56, max(ph) / 2.56, avg / 2.56))
        # last-third (steady gameplay) summary
        tail = ph[len(ph) * 2 // 3:]
        if tail:
            print('  PH steady (last third): avg=%.1f%% (n=%d)'
                  % (statistics.mean(tail) / 2.56, len(tail)))
        verdict_for(avg / 2.56)
    else:
        print('  !! No PH samples — UART not flowing or field absent. Check DBG_UART + Debug-UART OSD.')
    if pcs:
        from collections import Counter
        top = Counter(pcs).most_common(5)
        print('  PC top: ' + '  '.join('%s(%d)' % (p, n) for p, n in top))


def verdict_for(pct):
    if pct >= 90:
        v = 'BIG WIN (>=90%) — pursue page-mode SDRAM (Lever 1).'
    elif pct >= 60:
        v = 'MODEST (~60-90%) — page-mode helps ~1.1-1.4x; weigh vs effort.'
    elif pct >= 45:
        v = 'MARGINAL (~45-60%) — near break-even; small win at best.'
    else:
        v = 'BELOW BREAK-EVEN (<45%) — page-mode is SLOWER; DROP Lever 1.'
    print('  >>> VERDICT: %s' % v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--warm', type=int, default=180)
    ap.add_argument('--sample', type=int, default=30)
    ap.add_argument('--keys', action='store_true')
    ap.add_argument('--no-load', action='store_true', help='skip reload; sample running core')
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    c = connect()
    out, _ = run(c, 'md5sum %s; cat /tmp/CORENAME' % RBF_REMOTE)
    print('rbf/core:', out.strip().replace('\n', '  '))

    if not args.no_load:
        sftp = c.open_sftp()
        sftp.put(MGL_LOCAL, MGL_REMOTE)
        sftp.put(LOADER_LOCAL, LOADER_REMOTE)
        sftp.close()
        run(c, "printf '\\x0c' | dd of=%s bs=1 count=1 seek=10 conv=notrunc 2>/dev/null" % CFG_REMOTE)
        run(c, 'echo load_core %s > /dev/MiSTer_cmd' % RBF_REMOTE)
        time.sleep(12)
        print('load Doom MGL ...')
        run(c, 'echo load_core %s > /dev/MiSTer_cmd' % MGL_REMOTE)
        print('warming %ds (engine init -> menu) ...' % args.warm)
        time.sleep(args.warm)

    if args.keys:
        # try to enter gameplay from the menu: RETURN (select), then a few
        # frames, then RETURN again (new game / skill).
        run(c, 'python3 /tmp/mtype.py "{RET}"', t=10)
        time.sleep(3)
        run(c, 'python3 /tmp/mtype.py "{RET}"', t=10)
        time.sleep(5)

    print('sampling UART %ds (menu/gameplay) ...' % args.sample)
    out = capture_uart(c, args.sample, os.path.join(OUT_DIR, 'pagehit_uart.txt'))
    analyze(out)
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
