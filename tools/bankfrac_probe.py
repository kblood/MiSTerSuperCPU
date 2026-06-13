"""iter-31 bank-fraction probe (authoritative bank-$00 BRAM lever sizing).

Deploys the current _Test/C64.rbf, autoloads Doom, waits for the engine/menu,
then captures a UART window and parses the BF:/BW: fields emitted by the
BANKFRAC_OBSERVER (fpga64_sid_iec.vhd, reuses the dead HR/HW slot).

BF = bank-$00 accesses per last 256 total CPU SDRAM (cs_ram) accesses (0..FF;
     BF/2.56 = % of CPU SDRAM accesses that target bank $00).
BW = window-completion counter (must advance => observer is live).

Why this matters (operator question 2026-06-13): the real SuperCPU's FAST tier is
the 128KB SRAM (banks $00/$01); we run bank $00 in slow SDRAM. Moving bank $00
into an AUTHORITATIVE BRAM store (NOT a cache => no coherency/fill race => outside
the 6-dead-lever death class; and BRAM has no SDRAM read latency => a bank-$00
fast-fire has the full cadence budget for the ~20ns combinational path) accelerates
bank-$00 traffic only. Doom's instruction fetch is SuperRAM ($20) and stays
SDRAM-bound regardless, so the speedup is bounded by the bank-$00 access fraction
(zeropage + stack + the VIC framebuffer writes iter-30 found are the heavy ones).
This probe sizes that fraction BEFORE the multi-day VIC/REU bank-$00->BRAM
rearchitecture.

Decision rule (rough): if bank-$00 fast-fire takes those accesses from 4-apart to
~1-2-apart while SuperRAM stays 4-apart, effective speedup ~ 1/(1 - BF%*(3/4)).
  BF >= ~40% => ~1.4-1.5x => pursue the rearchitecture.
  BF ~ 25-40% => ~1.2-1.35x => weigh vs the VIC/REU coherency effort.
  BF < ~15% => ~<1.15x => drop (fetch-bound, bank-$00 BRAM not worth it).

Usage:
  python tools/bankfrac_probe.py             # load Doom, wait ~180s, sample 30s
  python tools/bankfrac_probe.py --warm N --sample N
  python tools/bankfrac_probe.py --no-load   # skip reload; sample running core
"""
import paramiko, time, os, sys, socket, re, argparse, statistics

HOST, USER, PASS = '192.168.50.130', 'root', '1'
MGL_LOCAL = 'tools/_doom_autoload.mgl'
LOADER_LOCAL = 'tools/doom_loader.prg'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload.mgl'
LOADER_REMOTE = '/media/fat/games/C64/doom_loader.prg'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG_REMOTE = '/media/fat/config/C64.cfg'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_autoload', 'bankfrac')

BF_RE = re.compile(r'BF:([0-9A-Fa-f]{2})')
BW_RE = re.compile(r'BW:([0-9A-Fa-f]{2})')
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


def verdict_for(pct):
    if pct >= 40:
        v = 'HIGH (>=40%) — bank-$00 BRAM + fast-fire ~1.4-1.5x; pursue rearchitecture.'
    elif pct >= 25:
        v = 'WORTH IT (~25-40%) — ~1.2-1.35x; weigh vs VIC/REU coherency effort.'
    elif pct >= 15:
        v = 'MODEST (~15-25%) — ~1.15-1.2x; marginal vs the multi-day rework.'
    else:
        v = 'LOW (<15%) — fetch-bound; bank-$00 BRAM not worth it.'
    print('  >>> VERDICT: %s' % v)


def analyze(out):
    bf = [int(m, 16) for m in BF_RE.findall(out)]
    bw = [int(m, 16) for m in BW_RE.findall(out)]
    pcs = PC_RE.findall(out)
    print('  UART lines: %d  BF samples: %d  BW samples: %d' % (out.count('\n'), len(bf), len(bw)))
    if bw:
        print('  BW (window-completion): first=%02X last=%02X  advanced=%s'
              % (bw[0], bw[-1], 'YES (observer live)' if bw[-1] != bw[0] else 'NO (frozen!)'))
    if bf:
        avg = statistics.mean(bf)
        print('  BF raw: min=%02X max=%02X avg=%.1f  (n=%d)' % (min(bf), max(bf), avg, len(bf)))
        print('  Bank-$00 fraction: min=%.1f%%  max=%.1f%%  avg=%.1f%%'
              % (min(bf) / 2.56, max(bf) / 2.56, avg / 2.56))
        tail = bf[len(bf) * 2 // 3:]
        if tail:
            print('  BF steady (last third): avg=%.1f%% (n=%d)'
                  % (statistics.mean(tail) / 2.56, len(tail)))
        verdict_for(avg / 2.56)
    else:
        print('  !! No BF samples — UART not flowing or field absent. Check DBG_UART + Debug-UART OSD.')
    if pcs:
        from collections import Counter
        top = Counter(pcs).most_common(5)
        print('  PC top: ' + '  '.join('%s(%d)' % (p, n) for p, n in top))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--warm', type=int, default=180)
    ap.add_argument('--sample', type=int, default=30)
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

    print('sampling UART %ds (menu/gameplay) ...' % args.sample)
    out = capture_uart(c, args.sample, os.path.join(OUT_DIR, 'bankfrac_uart.txt'))
    analyze(out)
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
