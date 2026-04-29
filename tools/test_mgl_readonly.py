#!/usr/bin/env python3
"""MGL pipe REU loading test - READ-ONLY against /media/fat/_Computer/.

Tests whether `echo load_core /media/fat/_Computer/doom.mgl > /dev/MiSTer_cmd`
successfully streams doom.reu into REU SDRAM on the vanilla upstream C64 core
that lives in /media/fat/_Computer/C64.rbf.

RULES (see feedback_mister_folder_layout.md):
  - DO NOT write anything into /media/fat/_Computer/. Vanilla-managed.
  - Our modified build lives ONLY in /media/fat/_Test/C64.rbf.
  - Write ONLY to /tmp/ and poll /proc/ - anything else is off-limits.

Evidence sources:
  1. /proc/<pid>/io rchar delta during MGL window (read() bytes accumulated)
  2. /proc/<pid>/fd polling for doom.reu (best-effort, file opens fast)
  3. MiSTer main log via stdbuf -oL -eL (best effort; some buffering may cost
     us post-exec output, but boot banner + early init usually come through)
  4. Screen state via md.cmd_screen before/after
  5. After KERNAL READY, single mtype.py batch that runs BASIC REU FETCH from
     REU $020010/$020011 and prints bytes. doom.reu byte 0x20010 = $04, byte
     0x20011 = $05. Non-zero result proves data landed in REU SDRAM region.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mister_debug as md


RBF_VANILLA = "/media/fat/_Computer/C64.rbf"   # READ-ONLY reference
MGL         = "/media/fat/_Computer/doom.mgl"  # READ-ONLY reference


BASIC = [
    # Print an identifying marker so we know the run is fresh
    '10 ?"--- reu verify ---"',
    # Standard REU register layout ($DF00=status $DF01=cmd $DF02-03=target
    #  $DF04-06=reu addr $DF07-08=len). These are at 57088+offset.
    '20 poke57090,0:poke57091,192',                 # target = $C000
    '30 poke57092,16:poke57093,0:poke57094,2',      # REU addr = $020010
    '40 poke57095,1:poke57096,0',                   # length = 1
    '50 poke49152,170:poke57089,145',               # sentinel, FETCH
    '60 ?"b010=";peek(49152);" exp 4"',
    # Second byte
    '70 poke57092,17:poke57093,0:poke57094,2',      # REU addr = $020011
    '80 poke57095,1:poke57096,0',                   # length = 1 (auto-reload)
    '90 poke49152,170:poke57089,145',               # sentinel, FETCH
    '100 ?"b011=";peek(49152);" exp 5"',
    # Bonus: try byte at $00004000 (doom header area usually non-zero)
    '110 poke57092,0:poke57093,64:poke57094,0',     # REU addr = $004000
    '120 poke57095,1:poke57096,0',
    '130 poke49152,170:poke57089,145',
    '140 ?"b4000=";peek(49152)',
    '150 ?"done"',
]


def ssh_show(cmd, timeout=10, quiet=False):
    out, err, rc = md.ssh(cmd, timeout=timeout)
    if not quiet:
        print(f"$ {cmd}")
        if out.strip(): print("  " + out.rstrip().replace("\n", "\n  "))
        if err.strip() and rc != 0: print("  ERR: " + err[:200])
    return out


def main():
    print("=" * 60)
    print("MGL pipe REU loading test (read-only against _Computer/)")
    print("=" * 60)

    # Step 0: Verify _Computer/ is pristine vanilla (sanity only - READ-ONLY)
    print("\n[0] verify _Computer/ rbfs are vanilla upstream")
    out = ssh_show(f"md5sum {RBF_VANILLA} /media/fat/_Computer/C64_20250828.rbf")
    if "32a3ef42a78ed8b255bed895d09b833c" not in out:
        print("ABORT: _Computer/ is not vanilla. Refusing to run.")
        print("Restore via: scp C64_MiSTer/releases/C64_20250828.rbf "
              "root@MiSTer:/media/fat/_Computer/{C64.rbf,C64_20250828.rbf}")
        return 1

    # Step 1: kill MiSTer and restart with vanilla rbf (fresh FPGA, fresh mtype state)
    print("\n[1] restart MiSTer main with vanilla core, line-buffered stdout")
    ssh_show("kill $(pidof MiSTer) 2>/dev/null; sleep 2; rm -f /tmp/mister.log; "
             f"stdbuf -oL -eL nohup /media/fat/MiSTer {RBF_VANILLA} "
             "> /tmp/mister.log 2>&1 &")
    print("  wait 10s for MiSTer main + FPGA + KERNAL ready...")
    time.sleep(10)

    # Verify a fresh pid
    pid = ssh_show("pidof MiSTer").strip()
    print(f"  MiSTer pid: {pid}")
    if not pid:
        print("ABORT: MiSTer didn't start"); return 1

    md.cmd_screen(["mgl_ro_before.png"])

    # Snapshot /proc/io baseline
    baseline = ssh_show(f"cat /proc/{pid}/io", quiet=True)
    print("  baseline /proc/io:")
    for ln in baseline.strip().splitlines():
        print("    " + ln)

    # Step 2: trigger MGL load via pipe
    print("\n[2] trigger doom.mgl via /dev/MiSTer_cmd pipe")
    ssh_show(f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")

    # Step 3: poll for file activity (0.3s granularity, 30s window)
    print("\n[3] poll /proc/fd + rchar for doom.reu activity (30s)")
    poll = r"""
pid_orig=$1
for i in $(seq 1 100); do
  pid=$(pidof MiSTer)
  if [ -z "$pid" ]; then
    echo "t$i pid=GONE"
    sleep 0.3
    continue
  fi
  rchar=$(grep ^rchar /proc/$pid/io 2>/dev/null | awk '{print $2}')
  doom=$(ls -l /proc/$pid/fd 2>/dev/null | grep -i doom | head -1 | sed 's/.*-> //')
  if [ -n "$doom" ]; then
    echo "t$i pid=$pid rchar=$rchar doom=$doom"
  elif [ "$(expr $i % 5)" = "0" ]; then
    echo "t$i pid=$pid rchar=$rchar"
  fi
  sleep 0.3
done
"""
    out, _, _ = md.ssh(f"sh -c '{poll}' _ {pid}", timeout=50)
    print(out)

    # Step 4: snapshot io counters post-MGL
    print("\n[4] /proc/io after MGL window")
    cur_pid = ssh_show("pidof MiSTer", quiet=True).strip()
    after = ssh_show(f"cat /proc/{cur_pid}/io", quiet=True)
    print("  post-MGL /proc/io:")
    for ln in after.strip().splitlines():
        print("    " + ln)

    # Mid-test screenshot
    md.cmd_screen(["mgl_ro_mid.png"])

    # Step 5: MiSTer log
    print("\n[5] MiSTer main log")
    log = ssh_show("cat /tmp/mister.log", quiet=True)
    for ln in log.rstrip().splitlines()[-40:]:
        print("    " + ln)

    # Step 6: wait for KERNAL, type BASIC verification (SINGLE mtype batch)
    print("\n[6] type BASIC verification program (single mtype.py call)")
    time.sleep(4)  # ensure BASIC is ready
    tokens = ["'new'", "enter"]
    for ln in BASIC:
        tokens.append("'" + ln + "'")
        tokens.append("enter")
    tokens.append("'run'")
    tokens.append("enter")
    cmd = "python3 /tmp/mtype.py " + " ".join(tokens)
    md.ssh(cmd, timeout=240)
    time.sleep(4)

    md.cmd_screen(["mgl_ro_result.png"])

    print("\n" + "=" * 60)
    print("DONE. Inspect mgl_ro_result.png for BASIC output.")
    print("  Expected (if MGL loaded doom.reu): b010=4, b011=5")
    print("  If MGL didn't load:                b010=0, b011=170 (sentinel)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
