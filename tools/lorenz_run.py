#!/usr/bin/env python3
"""Lorenz CPU Test Suite 2.15 runner for v274 baseline.

Mounts /media/fat/games/C64/lorenz_disk1.d64 via MGL, sends
`LOAD"*",8,1` + `RUN`, then takes a screenshot every POLL_S seconds.
Suite halts on first error; we capture the frozen screen + flag the
test name. Otherwise lets it run for MAX_RUN_S then stops.

Usage:
    python tools/lorenz_run.py [t65|scpu] [--mins N]

Per-mode results land in tools/lorenz_run/<mode>/. Final shot named
*_final.png. Series shots are timestamped.

CPU mode is set via cfg byte 10 mutation (status[82]=SuperCPU bit 2):
    T65:  byte10 = 0x08 (kickstart=1, scpu=0)
    SCPU: byte10 = 0x0C (kickstart=1, scpu=1)
"""
import os, sys, time, paramiko, hashlib

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
MGL = '/media/fat/_Test/lorenz_disk1.mgl'
RBF = '/media/fat/_Test/C64.rbf'
OUT_BASE = r'C:\LLM\C64\MiSTerSuperCPU\tools\lorenz_run'
MTYPE_REMOTE = '/tmp/mtype.py'
MTYPE_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mtype.py')

POLL_S = 30  # screenshot cadence
DEFAULT_MAX_MIN = 35  # cap per-mode runtime


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    # Keepalive so a long Lorenz run doesn't get the transport killed mid-poll.
    c.get_transport().set_keepalive(15)
    return c


def run(c, cmd, timeout=20):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def reconnect(old):
    try:
        old.close()
    except Exception:
        pass
    return ssh()


def set_cfg(c, val):
    run(c, "printf '\\x{:02x}' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(val, CFG))
    out, _ = run(c, "dd if={} bs=1 count=1 skip=10 2>/dev/null | xxd -p".format(CFG))
    return out.strip()


def ensure_mtype(c):
    out, _ = run(c, "test -f {} && echo present || echo missing".format(MTYPE_REMOTE))
    if 'present' in out:
        return
    # Upload via base64 cat — avoids paramiko sftp size-confirm flakiness on /tmp
    import base64
    with open(MTYPE_LOCAL, 'rb') as f:
        data = base64.b64encode(f.read()).decode()
    chunks = [data[i:i + 4096] for i in range(0, len(data), 4096)]
    run(c, "rm -f {}".format(MTYPE_REMOTE))
    for i, ch in enumerate(chunks):
        op = '>' if i == 0 else '>>'
        run(c, "echo '{}' {} {}.b64".format(ch, op, MTYPE_REMOTE))
    run(c, "base64 -d {}.b64 > {} && rm {}.b64".format(MTYPE_REMOTE, MTYPE_REMOTE, MTYPE_REMOTE))
    out, _ = run(c, "wc -c < {}".format(MTYPE_REMOTE))
    print('  mtype.py uploaded, size={}'.format(out.strip()))


def shot(c, dst_dir, name):
    os.makedirs(dst_dir, exist_ok=True)
    run(c, 'rm -f /media/fat/screenshots/C64/*.png')
    run(c, 'echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.5)
    out, _ = run(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1')
    remote = out.strip()
    if not remote:
        return None
    sftp = c.open_sftp()
    local = os.path.join(dst_dir, name + '.png')
    sftp.get(remote, local)
    sftp.close()
    return local


def img_md5(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, 'rb') as f:
        return hashlib.md5(f.read()).hexdigest()[:12]


def core_mtime(c):
    out, _ = run(c, "stat -c %Y /tmp/CORENAME 2>/dev/null")
    try:
        return int(out.strip())
    except Exception:
        return 0


def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else 't65').lower()
    max_min = DEFAULT_MAX_MIN
    if '--mins' in sys.argv:
        i = sys.argv.index('--mins')
        max_min = int(sys.argv[i + 1])

    if mode == 't65':
        cfg_val = 0x08
    elif mode == 'scpu':
        cfg_val = 0x0c
    else:
        print('mode must be t65 or scpu')
        return 1

    out_dir = os.path.join(OUT_BASE, mode)
    os.makedirs(out_dir, exist_ok=True)

    c = ssh()
    print('--- Lorenz Disk1 [{}] up to {} min ---'.format(mode, max_min))
    ensure_mtype(c)

    print('  cfg byte10 -> 0x{:02x}'.format(cfg_val))
    got = set_cfg(c, cfg_val)
    print('  cfg verified: {}'.format(got))

    # Reload core to pick up new cfg
    pre_mt = core_mtime(c)
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(RBF))
    deadline = time.time() + 25
    while time.time() < deadline:
        time.sleep(2)
        if core_mtime(c) != pre_mt:
            break
    print('  core reloaded; settling 8s for KERNAL READY')
    time.sleep(8)

    # Now mount the disk via MGL load_core (MGL replaces core+disk in one shot)
    pre_mt = core_mtime(c)
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(MGL))
    time.sleep(8)
    print('  MGL loaded, settling 4s before key sequence')
    time.sleep(4)

    # mtype: type LOAD"*",8,1 ENTER, wait 6s for load, RUN ENTER.
    # mtype is one-call-per-MiSTer-lifetime so chain it all in one invocation.
    keys = '\'LOAD\' \'"*",8,1\' enter wait:6 \'RUN\' enter'
    print('  sending key sequence: LOAD"*",8,1 + RUN')
    out, err = run(c,
                   'python3 {} {}'.format(MTYPE_REMOTE, keys),
                   timeout=45)
    if err.strip():
        print('  mtype stderr: {}'.format(err.strip()[:200]))

    # Initial screenshot to confirm input landed
    time.sleep(8)
    p0 = shot(c, out_dir, '00_after_run')
    print('  shot @ t=0:  {}  md5={}'.format(os.path.basename(p0) if p0 else 'NONE', img_md5(p0)))

    # Periodic monitoring
    deadline = time.time() + max_min * 60
    last_md5 = img_md5(p0)
    last_change = time.time()
    series = [(0, p0, last_md5)]

    try:
        while time.time() < deadline:
            time.sleep(POLL_S)
            ts = int(time.time() - (deadline - max_min * 60))
            name = '{:04d}s'.format(ts)
            try:
                p = shot(c, out_dir, name)
            except Exception as exc:
                print('  t={:5d}s  shot failed ({}); reconnecting'.format(ts, type(exc).__name__))
                c = reconnect(c)
                try:
                    p = shot(c, out_dir, name)
                except Exception as exc2:
                    print('  t={:5d}s  shot failed again ({}); skipping poll'.format(ts, type(exc2).__name__))
                    p = None
            m = img_md5(p)
            series.append((ts, p, m))
            changed = m is not None and m != last_md5
            marker = '  CHANGE' if changed else ''
            print('  t={:5d}s  {}  md5={}{}'.format(ts, os.path.basename(p) if p else 'NONE', m, marker))
            if changed:
                last_md5 = m
                last_change = time.time()
            elif m is not None and time.time() - last_change > 90:
                # Frozen >90s — likely halted (error or completion)
                print('  >>> screen frozen >90s, treating as halted')
                break
    finally:
        try:
            final = shot(c, out_dir, 'final')
        except Exception:
            try:
                c = reconnect(c)
                final = shot(c, out_dir, 'final')
            except Exception:
                final = None
        print('  FINAL: {}  md5={}'.format(os.path.basename(final) if final else 'NONE', img_md5(final)))

        summary_path = os.path.join(out_dir, '_summary.txt')
        with open(summary_path, 'w') as f:
            f.write('mode: {}\n'.format(mode))
            f.write('max_min: {}\n'.format(max_min))
            f.write('shots: {}\n'.format(len(series)))
            f.write('frozen_at: {}s ({})\n'.format(
                series[-1][0] if series else '?',
                'frozen' if (time.time() - last_change > 90) else 'time-cap'))
            f.write('final md5: {}\n'.format(img_md5(final)))
            f.write('\nseries:\n')
            for ts, p, m in series:
                f.write('  t={:5d}s  {}  md5={}\n'.format(ts, os.path.basename(p) if p else 'NONE', m))
        print('  summary -> {}'.format(summary_path))

        try:
            c.close()
        except Exception:
            pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
