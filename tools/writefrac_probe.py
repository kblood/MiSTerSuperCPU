"""iter-30 write-fraction probe (Track A1).

Deploys the current _Test/C64.rbf, autoloads Doom (reusing the doom_autoload
MGL + loader), waits for the engine/menu, then captures a sustained UART window
and parses the WF:/WW: fields emitted by the WRITEFRAC_OBSERVER
(fpga64_sid_iec.vhd, reuses the dead HR/HW slot the iter-29 page-hit observer
used).

WF = SuperRAM WRITES per last 256 SuperRAM CPU SDRAM accesses (0..FF;
     WF/2.56 = % of SuperRAM CPU accesses that are stores).
WW = window-completion counter (must advance => observer is live).

Why this matters (project plan Track A1): VICE's xscpu64 gets its speed from a
memory-timing model whose centerpiece is a POSTED WRITE BUFFER — writes are
free, reads cannot be (scpu64cpu.c buffer_finish/wait_buffer). A 1-entry FPGA
posted-write buffer's speedup is therefore bounded by the write fraction. This
probe measures that fraction on the real Doom workload BEFORE committing to the
Track C write-buffer RTL + the one gated HW build.

Decision rule (rough, SuperRAM-bound code): the buffer removes ~WF of the store
cadence. WF >= ~30% => worth the GHDL+build effort (~1.2-1.35x). WF < ~10% =>
payoff caps near ~1.1x; reconsider.

Usage:
  python tools/writefrac_probe.py            # load Doom, wait ~180s, sample 30s
  python tools/writefrac_probe.py --warm N    # seconds to wait before sampling
  python tools/writefrac_probe.py --sample N  # seconds of UART to capture
  python tools/writefrac_probe.py --keys      # after warm, try to enter gameplay
  python tools/writefrac_probe.py --no-load   # skip reload; sample running core
"""
import paramiko, time, os, sys, socket, re, argparse, statistics

HOST, USER, PASS = '192.168.50.130', 'root', '1'
MGL_LOCAL = 'tools/_doom_autoload.mgl'
LOADER_LOCAL = 'tools/doom_loader.prg'
MGL_REMOTE = '/media/fat/_Computer/_SuperCPU/_doom_autoload.mgl'
LOADER_REMOTE = '/media/fat/games/C64/doom_loader.prg'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
CFG_REMOTE = '/media/fat/config/C64.cfg'
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'doom_autoload', 'writefrac')

WF_RE = re.compile(r'WF:([0-9A-Fa-f]{2})')
WW_RE = re.compile(r'WW:([0-9A-Fa-f]{2})')
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
        v = 'HIGH (>=40%) — posted write buffer is high-value; build Track C.'
    elif pct >= 25:
        v = 'WORTH IT (~25-40%) — ~1.2-1.35x ceiling; proceed with GHDL+build.'
    elif pct >= 10:
        v = 'MODEST (~10-25%) — ~1.1-1.2x; weigh vs effort.'
    else:
        v = 'LOW (<10%) — payoff caps ~1.1x; reconsider write buffer priority.'
    print('  >>> VERDICT: %s' % v)


def analyze(out):
    wf = [int(m, 16) for m in WF_RE.findall(out)]
    ww = [int(m, 16) for m in WW_RE.findall(out)]
    pcs = PC_RE.findall(out)
    print('  UART lines: %d  WF samples: %d  WW samples: %d' % (out.count('\n'), len(wf), len(ww)))
    if ww:
        print('  WW (window-completion): first=%02X last=%02X  advanced=%s'
              % (ww[0], ww[-1], 'YES (observer live)' if ww[-1] != ww[0] else 'NO (frozen!)'))
    if wf:
        avg = statistics.mean(wf)
        print('  WF raw: min=%02X max=%02X avg=%.1f  (n=%d)' % (min(wf), max(wf), avg, len(wf)))
        print('  Write fraction: min=%.1f%%  max=%.1f%%  avg=%.1f%%'
              % (min(wf) / 2.56, max(wf) / 2.56, avg / 2.56))
        tail = wf[len(wf) * 2 // 3:]
        if tail:
            print('  WF steady (last third): avg=%.1f%% (n=%d)'
                  % (statistics.mean(tail) / 2.56, len(tail)))
        verdict_for(avg / 2.56)
    else:
        print('  !! No WF samples — UART not flowing or field absent. Check DBG_UART + Debug-UART OSD.')
    if pcs:
        from collections import Counter
        top = Counter(pcs).most_common(5)
        print('  PC top: ' + '  '.join('%s(%d)' % (p, n) for p, n in top))


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
        run(c, 'python3 /tmp/mtype.py "{RET}"', t=10)
        time.sleep(3)
        run(c, 'python3 /tmp/mtype.py "{RET}"', t=10)
        time.sleep(5)

    print('sampling UART %ds (menu/gameplay) ...' % args.sample)
    out = capture_uart(c, args.sample, os.path.join(OUT_DIR, 'writefrac_uart.txt'))
    analyze(out)
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
