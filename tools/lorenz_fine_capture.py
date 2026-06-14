#!/usr/bin/env python3
"""Fine-grained Lorenz scpu capture to diagnose the step-6 early-stop.
Sets scpu mode, loads the autoload MGL, then snapshots every ~9s for ~170s
into tools/lorenz_run/scpu_fine/. Reuses lorenz_run helpers."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lorenz_run as L

OUT = os.path.join(L.OUT_BASE, 'scpu_fine')
DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 170

def main():
    os.makedirs(OUT, exist_ok=True)
    c = L.ssh()
    print('--- fine scpu capture ---')
    print('cfg ->', L.set_cfg(c, 0x0c))
    pre = L.core_mtime(c)
    L.run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(L.RBF))
    dl = time.time() + 25
    while time.time() < dl:
        time.sleep(2)
        if L.core_mtime(c) != pre:
            break
    time.sleep(8)
    sftp = c.open_sftp()
    sftp.put(L.AUTOLOAD_PRG_LOCAL, L.AUTOLOAD_PRG_REMOTE)
    mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" path="{}"/>\n'
           '<file delay="8" type="f" index="1" path="{}"/>\n'
           '</mistergamedescription>\n').format(L.DISK_PATH, L.AUTOLOAD_PRG_REMOTE)
    with sftp.open(L.MGL_AUTO, 'w') as f:
        f.write(mgl)
    sftp.close()
    pre = L.core_mtime(c)
    L.run(c, 'echo load_core {} > /dev/MiSTer_cmd'.format(L.MGL_AUTO))
    time.sleep(15)
    t0 = time.time()
    last = None
    while time.time() - t0 < DUR:
        ts = int(time.time() - t0)
        try:
            p = L.shot(c, OUT, '{:04d}s'.format(ts))
        except Exception as e:
            print('  t={:4d}s shot fail {}; reconnect'.format(ts, type(e).__name__))
            c = L.reconnect(c); continue
        m = L.img_md5(p)
        mark = ' CHANGE' if m != last else ''
        print('  t={:4d}s {} md5={}{}'.format(ts, os.path.basename(p) if p else 'NONE', m, mark))
        last = m
        time.sleep(6)
    print('done ->', OUT)

if __name__ == '__main__':
    main()
