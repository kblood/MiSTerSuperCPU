#!/usr/bin/env python3
"""SCPU real-software compatibility sweep (HW, unattended).

The speed frontier is closed (k=2 bank-$00 fast-fire shipped, k=1 STA-dead);
the live frontier is non-instruction COMPAT: run real SuperCPU software on
hardware and triage what breaks against the known stubs/timing gaps
(WriteSmart $D074-$D077/$D0B3, bootmap OS ROM $F0-$FF, badline-during-turbo,
DOS extension $D0BE/$D0BF). See docs/supercpu_feature_status.md §6/§13.

For each target program it:
  1. sets cfg byte10 -> 0x0c (scpu mode),
  2. mounts the disk + a generated `LOAD"NAME",8,1` BASIC autoload PRG via MGL
     (MiSTer start_strk synthesizes RUN, same path as lorenz_run.py),
  3. captures screenshots at intervals + a UART tail,
  4. writes everything under tools/scpu_compat_sweep/<disk>/<prog>/.

COOPERATION: the shared MiSTer (192.168.50.130) is also used by the CD32/
Minimig slice. This script REFUSES to load_core unless /tmp/CORENAME is C64,
MENU, or empty — run it only when the rig is free.

Usage:
  python tools/scpu_compat_sweep.py --list            # show planned targets
  python tools/scpu_compat_sweep.py                    # run full sweep
  python tools/scpu_compat_sweep.py --only "KICKS A"   # one target (substring)
  python tools/scpu_compat_sweep.py --secs 240         # per-target capture window
"""
import os, sys, time, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lorenz_run as L

OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\scpu_compat_sweep'
MGL = '/media/fat/_Test/scpu_compat_sweep.mgl'
PRG_REMOTE = '/media/fat/games/C64/scpu_sweep_autoload.prg'

# Targets: (disk image on rig, load-name, slug, capture seconds).
# load-name "*" = first PRG on disk (the demo's own loader/menu).
TARGETS = [
    ('/media/fat/games/C64/SCPU1.D64',            '*',                'scpu1_loader',  240),
    ('/media/fat/games/C64/SCPU1.D64',            'SUPERCPU KICKS A', 'kicks_a',       180),
    ('/media/fat/games/C64/SCPU1.D64',            'SUPERCPU KICKS B', 'kicks_b',       180),
    ('/media/fat/games/C64/SCPU1.D64',            'SUPERCPU KICKS C', 'kicks_c',       180),
    ('/media/fat/games/C64/CP-ClockF83_1.3.D64',  'CP-CLOCK-1.3',     'cp_clock',      120),
]


def make_autoload_prg(name):
    """BASIC line 0: LOAD"<name>",8,1 at $0801 (start_strk auto-RUNs it)."""
    LOAD_ADDR = 0x0801
    petscii_name = name.upper().encode('ascii', 'replace')
    tokens = bytes([0x93]) + b'"' + petscii_name + b'"' + bytes(
        [0x2C, 0x38, 0x2C, 0x31, 0x00])           # ,8,1 <eol>
    next_line = LOAD_ADDR + 4 + len(tokens)
    header = bytes([next_line & 0xFF, (next_line >> 8) & 0xFF, 0x00, 0x00])
    return bytes([LOAD_ADDR & 0xFF, LOAD_ADDR >> 8]) + header + tokens + bytes([0, 0])


def coop_ok(c):
    core = L.run(c, 'cat /tmp/CORENAME 2>/dev/null').strip()
    if core in ('', 'C64', 'MENU'):
        return True, core
    return False, core


def run_target(c, disk, name, slug, secs):
    out = os.path.join(OUT, slug)
    os.makedirs(out, exist_ok=True)
    print('\n=== target: {} | disk={} | name="{}" | {}s ==='.format(
        slug, os.path.basename(disk), name, secs))

    # upload generated autoload PRG + MGL (disk on s:0, PRG on f:1)
    prg = make_autoload_prg(name)
    sftp = c.open_sftp()
    with sftp.open(PRG_REMOTE, 'wb') as f:
        f.write(prg)
    mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" path="{}"/>\n'
           '<file delay="8" type="f" index="1" path="{}"/>\n'
           '</mistergamedescription>\n').format(disk, PRG_REMOTE)
    with sftp.open(MGL, 'w') as f:
        f.write(mgl)
    sftp.close()

    pre = L.core_mtime(c)
    L.run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(MGL))
    # wait for the core to actually reload
    dl = time.time() + 30
    while time.time() < dl:
        time.sleep(2)
        if L.core_mtime(c) != pre:
            break
    time.sleep(12)                                  # let disk mount + autoload RUN

    # UART tail in the background; screenshots in the foreground
    L.run(c, 'stty -F /dev/ttyS1 115200 raw -echo 2>/dev/null; '
             'timeout {} cat /dev/ttyS1 > /tmp/sweep_uart.txt 2>/dev/null &'.format(secs))
    t0 = time.time()
    last = None
    while time.time() - t0 < secs:
        ts = int(time.time() - t0)
        try:
            p = L.shot(c, out, '{:04d}s'.format(ts))
            m = L.img_md5(p)
        except Exception as e:
            print('  t={:4d}s shot fail {}; reconnect'.format(ts, type(e).__name__))
            c = L.reconnect(c); continue
        mark = ' CHANGE' if m != last else ''
        print('  t={:4d}s md5={}{}'.format(ts, m, mark))
        last = m
        time.sleep(L.POLL_S)
    # pull UART
    try:
        sftp = c.open_sftp()
        sftp.get('/tmp/sweep_uart.txt', os.path.join(out, 'uart.txt'))
        sftp.close()
    except Exception as e:
        print('  uart pull failed:', e)
    print('  -> {}'.format(out))
    return c


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--only', default=None, help='substring filter on slug/name')
    ap.add_argument('--secs', type=int, default=None, help='override capture window')
    args = ap.parse_args(argv[1:])

    targets = TARGETS
    if args.only:
        q = args.only.lower()
        targets = [t for t in TARGETS if q in t[2].lower() or q in t[1].lower()]
    if args.secs:
        targets = [(d, n, s, args.secs) for (d, n, s, _) in targets]

    if args.list:
        print('Planned SCPU compat-sweep targets:')
        for d, n, s, sec in targets:
            print('  {:14s} name="{}"  ({}s)  <- {}'.format(s, n, sec, os.path.basename(d)))
        return 0

    os.makedirs(OUT, exist_ok=True)
    c = L.ssh()
    ok, core = coop_ok(c)
    if not ok:
        print('REFUSING: rig busy, CORENAME="{}" (not C64/MENU/empty). '
              'Run when the rig is free.'.format(core))
        c.close(); return 2
    print('rig free (CORENAME="{}"); cfg -> 0x0c'.format(core))
    L.set_cfg(c, 0x0c)
    for d, n, s, sec in targets:
        c = run_target(c, d, n, s, sec)
    c.close()
    print('\nsweep done ->', OUT)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
