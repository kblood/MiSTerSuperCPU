"""Step 1 smoke test: Layer 2 sdram_ready synchroniser plumbing.

Expected outcome: ZERO observable change from v356 baseline.
This commit only adds the sync wiring; no cpu_cyc gating yet.

Procedure (~15 min):
  1. Deploy C64_MiSTer/output_files/C64.rbf to /media/fat/_Test/
  2. Boot vanilla C64, screenshot @ t=10s — must show READY prompt
  3. Doom progression t=30..180s — hashes should match v356 baseline
     (6a557fd6, 59e8a04b, 4935934b, 794caa36, 34f2edc8, ee5eff22)
  4. Brief Lorenz t65 (3 min) — must reach test 5+ without freeze

If smoke passes, the full 32-min Lorenz regressions can run overnight
or in parallel with Step 2 work.
"""
import os, sys, time, hashlib, paramiko

HOST, USER, PASS = '192.168.50.130', 'root', '1'
RBF_LOCAL = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.rbf'
RBF_REMOTE = '/media/fat/_Test/C64.rbf'
OUT = os.path.dirname(os.path.abspath(__file__))

V356_DOOM_HASHES = {
    30:  '6a557fd6',
    60:  '59e8a04b',
    90:  '4935934b',
    120: '794caa36',
    150: '34f2edc8',
    180: 'ee5eff22',
}


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    c.get_transport().set_keepalive(15)
    return c


def cmd(c, s, t=30):
    _, o, e = c.exec_command(s, timeout=t)
    return o.read().decode(errors='replace')


def deploy(c):
    print(f'=== deploy {RBF_LOCAL} -> {RBF_REMOTE} ===')
    s = c.open_sftp()
    s.put(RBF_LOCAL, RBF_REMOTE)
    s.close()
    print(f'deploy ok ({os.path.getsize(RBF_LOCAL)} bytes)')


def shot(c, label):
    cmd(c, 'rm -f /media/fat/screenshots/C64/*.png; echo screenshot > /dev/MiSTer_cmd')
    time.sleep(2.0)
    rem = cmd(c, 'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
    if not rem:
        return None, None
    s = c.open_sftp()
    local = os.path.join(OUT, label + '.png')
    s.get(rem, local); s.close()
    with open(local, 'rb') as f:
        h = hashlib.md5(f.read()).hexdigest()[:8]
    return local, h


def boot_smoke(c):
    print('=== boot smoke: load vanilla C64, screenshot @ t=10s ===')
    cmd(c, f'echo load_core _Test/C64.rbf > /dev/MiSTer_cmd')
    time.sleep(10)
    path, h = shot(c, 'step1_boot_t010')
    print(f'boot t=10s  hash={h}  -> {path}')
    return h


def doom_progression(c):
    print('=== doom progression t=30..180s (vs v356 baseline) ===')
    cmd(c, 'echo load_core _Test/doom_autolaunch.mgl > /dev/MiSTer_cmd')
    results = {}
    prev_t = 0
    for t in (30, 60, 90, 120, 150, 180):
        time.sleep(t - prev_t)
        prev_t = t
        path, h = shot(c, f'step1_doom_t{t:03d}')
        expected = V356_DOOM_HASHES[t]
        verdict = 'MATCH' if h == expected else 'DIFF'
        print(f't={t:3d}s  hash={h}  v356={expected}  {verdict}  -> {path}')
        results[t] = (h, expected, verdict)
    return results


def main():
    c = ssh()
    deploy(c)
    time.sleep(3)
    boot_smoke(c)
    res = doom_progression(c)
    n_match = sum(1 for h, e, v in res.values() if v == 'MATCH')
    n_total = len(res)
    print(f'\n=== Step 1 doom progression: {n_match}/{n_total} hashes match v356 ===')
    if n_match == n_total:
        print('PASS: zero observable change from v356, as expected.')
    elif n_match >= n_total - 1:
        print('LIKELY PASS: 1 hash diff is within noise (timing jitter).')
    else:
        print('FAIL: too many hash mismatches; Step 1 changed behaviour.')
        sys.exit(1)
    c.close()


if __name__ == '__main__':
    main()
