#!/usr/bin/env python3
"""Run an arbitrary C64 .d64 on the MiSTer in SuperCPU (native-capable) mode.

This is the harness for the SCPU *library compatibility sweep* (feature_status
§13 #9): mount a real 3rd-party SuperCPU title/demo disk, auto-boot its first
file, and capture a screenshot series so we can judge whether it detects the
SCPU, accelerates, and renders.

Reuses the proven lorenz_run.py machinery:
  - cfg byte 10 -> 0x0C selects SuperCPU mode (status[82]=SuperCPU bit set).
  - MGL mounts the disk (type="s" index=0) AND loads a tiny tokenized
    `LOAD"*",8,1` BASIC PRG (type="f" index=1); MiSTer's start_strk synthesizes
    the RUN keystroke, which chains to the disk's first file.
  - No keyboard injection needed.

Usage:
    python tools/scpu_compat/run_d64_scpu.py <local.d64> [--mins N] [--name TAG]

Shots land in tools/scpu_compat/run/<TAG>/. The demo is multi-disk; this runs
disk 1 only (boot + first parts) which is the SCPU-detect + accelerate signal.
Checks /tmp/CORENAME first; writes a session lock for the deploy+test span.
"""
import os, sys, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
CFG = '/media/fat/config/C64.cfg'
RBF = '/media/fat/_Test/C64.rbf'
MGL = '/media/fat/_Test/scpu_compat_autoload.mgl'
AUTOLOAD_PRG_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  '..', 'test_cart', 'out', 'lorenz_autoload.prg')
AUTOLOAD_PRG_REMOTE = '/media/fat/games/C64/_compat_autoload.prg'
DISK_REMOTE = '/media/fat/games/C64/_compat_disk.d64'
LOCK = '/tmp/mister_session.lock'
OUT_BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'run')
POLL_S = 20


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(15)
    return c


def run(c, cmd, timeout=25):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors='replace'), e.read().decode(errors='replace')


def core_mtime(c):
    out, _ = run(c, "stat -c %Y /tmp/CORENAME 2>/dev/null")
    try:
        return int(out.strip())
    except Exception:
        return 0


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


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d64 = sys.argv[1]
    mins = 6
    tag = os.path.splitext(os.path.basename(d64))[0]
    if '--mins' in sys.argv:
        mins = int(sys.argv[sys.argv.index('--mins') + 1])
    if '--name' in sys.argv:
        tag = sys.argv[sys.argv.index('--name') + 1]
    out_dir = os.path.join(OUT_BASE, tag)
    os.makedirs(out_dir, exist_ok=True)

    c = ssh()
    core, _ = run(c, 'cat /tmp/CORENAME 2>/dev/null')
    print('  /tmp/CORENAME = {!r}'.format(core.strip()))
    if core.strip() == 'Minimig':
        print('  >>> Minimig is the shared CD32 agent core — backing off.')
        return 2

    # Reserve for the deploy+test span only.
    run(c, "echo \"agent=c64 task='scpu-compat-sweep {}' since=$(date -Iseconds)\" > {}".format(tag, LOCK))

    # SuperCPU mode
    run(c, "printf '\\x0c' | dd of={} bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(CFG))
    got, _ = run(c, "dd if={} bs=1 count=1 skip=10 2>/dev/null | xxd -p".format(CFG))
    print('  cfg byte10 -> {} (scpu)'.format(got.strip()))

    # Upload disk + autoload PRG
    sftp = c.open_sftp()
    print('  uploading {} ...'.format(d64))
    sftp.put(d64, DISK_REMOTE)
    sftp.put(os.path.abspath(AUTOLOAD_PRG_LOCAL), AUTOLOAD_PRG_REMOTE)
    mgl = ('<mistergamedescription>\n'
           '<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" path="{}"/>\n'
           '<file delay="8" type="f" index="1" path="{}"/>\n'
           '</mistergamedescription>\n').format(DISK_REMOTE, AUTOLOAD_PRG_REMOTE)
    with sftp.open(MGL, 'w') as f:
        f.write(mgl)
    sftp.close()
    print('  MGL ready; loading core + disk + autoload')

    pre = core_mtime(c)
    run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(MGL))
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(2)
        if core_mtime(c) != pre:
            break
    time.sleep(16)  # disk mount (delay 2) + PRG load (delay 8) + BASIC chain

    p0 = shot(c, out_dir, '00_boot')
    print('  t=    0s  {}  md5={}'.format(os.path.basename(p0) if p0 else 'NONE', img_md5(p0)))
    series = [(0, p0, img_md5(p0))]
    last = img_md5(p0)

    end = time.time() + mins * 60
    while time.time() < end:
        time.sleep(POLL_S)
        ts = int(time.time() - (end - mins * 60))
        try:
            p = shot(c, out_dir, '{:04d}s'.format(ts))
        except Exception as exc:
            print('  t={:5d}s  shot err {}'.format(ts, type(exc).__name__)); continue
        m = img_md5(p)
        ch = '  CHANGE' if (m and m != last) else ''
        print('  t={:5d}s  {}  md5={}{}'.format(ts, os.path.basename(p) if p else 'NONE', m, ch))
        series.append((ts, p, m))
        if m:
            last = m

    final = shot(c, out_dir, 'final')
    with open(os.path.join(out_dir, '_summary.txt'), 'w') as f:
        f.write('disk: {}\nmode: scpu\nmins: {}\n\n'.format(d64, mins))
        for ts, p, m in series:
            f.write('  t={:5d}s  {}  md5={}\n'.format(ts, os.path.basename(p) if p else 'NONE', m))
    # Release the lock; leave CORENAME=C64 (caller decides whether to exit core).
    run(c, 'rm -f {}'.format(LOCK))
    print('  released session lock. shots in {}'.format(out_dir))
    c.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
