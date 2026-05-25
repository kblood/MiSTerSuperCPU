#!/usr/bin/env python3
"""v13e MCP regression: write-only gate on CIA1 AND CIA2.

Tests:
  1) Boot to READY (sanity)
  2) LOAD"$",8 directory listing — must still work (regression check)
  3) LOAD"*",8,1 full PRG load — the new target

Pass if all three reach READY/post-LOAD state.
"""
import os, sys, time, re, paramiko, glob

HOST, USER, PASS = '192.168.50.130', 'root', '1'
REMOTE_RBF = '/media/fat/_Test/C64.rbf'
OUT = r'C:\LLM\C64\MiSTerSuperCPU\tools\v13e_test'

# Auto-detect latest local build (overwritten by build_c64.ps1 to repo root)
def find_rbf():
    cand = glob.glob(r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\*.rbf') + \
           glob.glob(r'C:\LLM\C64\MiSTerSuperCPU\*.rbf')
    cand = [c for c in cand if 'C64' in os.path.basename(c)]
    cand.sort(key=os.path.getmtime, reverse=True)
    return cand[0] if cand else None


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, t=15):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode(errors='replace').strip()


def deploy(c, src):
    sftp = c.open_sftp()
    sftp.put(src, REMOTE_RBF)
    sftp.close()


def screenshot(c, dest):
    c.exec_command('echo "screenshot" > /dev/MiSTer_cmd', timeout=5)
    time.sleep(2)
    files = run(c, "ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    if files:
        sftp = c.open_sftp(); sftp.get(files, dest); sftp.close()
        return True
    return False


def analyze(text, secs):
    lines = [l for l in text.splitlines() if 'IF:' in l and 'PC:' in l]
    if not lines: return None
    parse = lambda l: dict(re.findall(r'(\w+):([0-9A-F]+)', l))
    first, last = parse(lines[0]), parse(lines[-1])
    pcs = [parse(l).get('PC', '?') for l in lines]
    hist = {}
    for p in pcs: hist[p] = hist.get(p, 0) + 1
    return {
        'lines': len(lines),
        'first_IF': first.get('IF', '?'), 'last_IF': last.get('IF', '?'),
        'first_IM': first.get('IM', '?'), 'last_IM': last.get('IM', '?'),
        'first_DR': first.get('DR', '?'), 'last_DR': last.get('DR', '?'),
        'first_D9': first.get('D9', '?'), 'last_D9': last.get('D9', '?'),
        'first_PC': first.get('PC', '?'), 'last_PC': last.get('PC', '?'),
        'unique_pcs': len(hist),
        'top_pc': sorted(hist.items(), key=lambda x: -x[1])[:5],
        'secs': secs,
        # Option F: CIA1 IM/CR; Option G: CIA2 M2/T2/PA/PB/DA/DB
        'first_IM': first.get('IM', '?'), 'last_IM': last.get('IM', '?'),
        'first_CR': first.get('CR', '?'), 'last_CR': last.get('CR', '?'),
        'first_M2': first.get('M2', '?'), 'last_M2': last.get('M2', '?'),
        'first_T2': first.get('T2', '?'), 'last_T2': last.get('T2', '?'),
        'first_PA': first.get('PA', '?'), 'last_PA': last.get('PA', '?'),
        'first_PB': first.get('PB', '?'), 'last_PB': last.get('PB', '?'),
        'first_DA': first.get('DA', '?'), 'last_DA': last.get('DA', '?'),
        'first_DB': first.get('DB', '?'), 'last_DB': last.get('DB', '?'),
        # PA stability set during stage (unique values seen across all samples)
        'pa_set': sorted({parse(l).get('PA', '?') for l in lines}),
        'pb_set': sorted({parse(l).get('PB', '?') for l in lines}),
        'da_set': sorted({parse(l).get('DA', '?') for l in lines}),
        'db_set': sorted({parse(l).get('DB', '?') for l in lines}),
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    rbf = sys.argv[1] if len(sys.argv) > 1 else find_rbf()
    if not rbf or not os.path.exists(rbf):
        print(f'no rbf found: {rbf}'); return 2
    print(f'Using rbf: {rbf}')

    c = ssh()
    cn = run(c, 'cat /tmp/CORENAME 2>/dev/null')
    if cn and cn != 'MENU' and not cn.startswith('C64'):
        print(f'ABORT: {cn!r}'); return 3
    run(c, "echo 'agent=c64 task=v13e-test' > /tmp/mister_session.lock")

    sftp = c.open_sftp()
    sftp.put(r'C:\LLM\C64\MiSTerSuperCPU\tools\mtype.py', '/tmp/mtype.py')
    sftp.close()

    print('Deploying...')
    deploy(c, rbf)

    mgl = ('<mistergamedescription>\n<rbf>_Test/C64</rbf>\n'
           '<file delay="2" type="s" index="0" '
           'path="/media/fat/games/C64/lorenz_disk1.d64"/>\n'
           '</mistergamedescription>\n')
    run(c, f"cat > /tmp/v13e.mgl <<'EOF'\n{mgl}EOF")
    run(c, "printf '\\x0c' | dd of=/media/fat/config/C64.cfg bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
    c.exec_command('echo load_core /tmp/v13e.mgl > /dev/MiSTer_cmd', timeout=5)
    time.sleep(12)
    run(c, 'stty -F /dev/ttyS1 115200 raw -echo')

    # Stage 1: boot baseline
    print('Stage 1: boot baseline (5s)')
    boot = run(c, "timeout 5 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n'", t=15)
    open(os.path.join(OUT, 's1_boot.txt'), 'w').write(boot)
    screenshot(c, os.path.join(OUT, 's1_boot.png'))

    # Stage 2: LOAD"$",8 — must still work
    print('Stage 2: LOAD"$",8 — directory')
    run(c, """python3 /tmp/mtype.py 'load "$",8' enter""", t=10); time.sleep(0.3)
    dollar = run(c, "timeout 60 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n'", t=70)
    open(os.path.join(OUT, 's2_dollar.txt'), 'w').write(dollar)
    screenshot(c, os.path.join(OUT, 's2_dollar.png'))

    # Settle, then check PC is in BASIC idle
    print('Stage 2b: settle 30s, check BASIC idle')
    settle = run(c, "timeout 30 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n'", t=40)
    open(os.path.join(OUT, 's2b_settle.txt'), 'w').write(settle)
    screenshot(c, os.path.join(OUT, 's2b_settle.png'))

    # Stage 3: LOAD"*",8,1 — the NEW target
    print('Stage 3: LOAD"*",8,1 — full PRG')
    run(c, """python3 /tmp/mtype.py 'load "*",8,1' enter""", t=10); time.sleep(0.3)
    star = run(c, "timeout 120 cat /dev/ttyS1 2>/dev/null | tr -dc '[:print:]\\n'", t=140)
    open(os.path.join(OUT, 's3_star.txt'), 'w').write(star)
    screenshot(c, os.path.join(OUT, 's3_star.png'))

    c.close()

    print('\n' + '=' * 60)
    for tag, txt, sec in [('BOOT', boot, 5), ('LOAD-DOLLAR', dollar, 60),
                          ('SETTLE', settle, 30), ('LOAD-STAR', star, 120)]:
        a = analyze(txt, sec)
        print(f'\n--- {tag} ({sec}s) ---')
        if not a: print('  no UART'); continue
        d_if = int(a['last_IF'], 16) - int(a['first_IF'], 16) if a['last_IF'] != '?' else 0
        d_dr = int(a['last_DR'], 16) - int(a['first_DR'], 16) if a['last_DR'] != '?' else 0
        print(f'  IF d={d_if} ({d_if/sec:.1f}/s), DR d={d_dr}, IM {a["first_IM"]}->{a["last_IM"]} CR {a["first_CR"]}->{a["last_CR"]}')
        print(f'  CIA2 M2 {a["first_M2"]}->{a["last_M2"]} T2 {a["first_T2"]}->{a["last_T2"]}')
        print(f'  CIA2 PA set={a["pa_set"]} DA set={a["da_set"]}')
        print(f'  CIA2 PB set={a["pb_set"]} DB set={a["db_set"]}')
        print(f'  PC {a["first_PC"]} -> {a["last_PC"]} unique={a["unique_pcs"]}')
        print(f'  top PCs: {a["top_pc"][:3]}')

    print('\nLook at screenshots: s3_star.png — pass if READY visible')

if __name__ == '__main__':
    sys.exit(main() or 0)
