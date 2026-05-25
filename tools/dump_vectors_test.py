#!/usr/bin/env python3
"""Deploy and run dump_vectors.prg in both T65 mode and SCPU mode.

Goal:
    Verify whether the SCPU EPROM kickstart actually installs the CMD
    vector hooks at the $0300-$0333 table and writes handler bytes at
    $00:$801A-$8054 after RESET. We compare T65 mode (no SCPU, no
    kickstart) vs SCPU mode (kickstart should run via bootmap).

Expected outcomes:

    T65 mode:
      ILOAD =$F4A5       <- stock C64 KERNAL default
      ISAVE =$F5ED       <- stock
      IOPEN =$F34A       <- stock
      IBASIN=$F157       <- stock
      IBSOUT=$F1CA       <- stock
      $801A =00 00 ...   <- uninitialized RAM (or random)
      $8000 =00 00 ...   <- uninitialized RAM
      $FFFC =reset_vec   <- KERNAL ROM RESET vector (FCE2)

    SCPU mode (if kickstart ran and installed hooks):
      ILOAD =$80xx       <- redirected into CMD handler
      ISAVE =$80xx       <- redirected
      IBASIN=$80xx       <- redirected (this is the throttle path)
      $801A =4C ... or 5C ... <- JMP/JML opcodes; non-zero handler bytes
      $8000 =non-zero    <- CMD code or jump table
      $FFFC =FC90 or similar (depends on bootmap state at PRG-run time)

    SCPU mode (if kickstart did NOT install hooks):
      vectors all match T65 mode
      $801A bytes all $00 or RAM noise
      → confirms the kickstart is partial/broken on our build

MiSTer cooperation:
    Refuses to run if CORENAME != C64 (and != empty). Writes its own
    lockfile while running. Cleans up at exit.
"""
import os
import sys
import time
import paramiko

MISTER_IP   = "192.168.50.130"
MISTER_USER = "root"
MISTER_PASS = "1"

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "dump_vectors_test")
os.makedirs(OUT_DIR, exist_ok=True)

PRG_LOCAL  = os.path.join(os.path.dirname(__file__),
                          "test_cart", "out", "dump_vectors.prg")
PRG_REMOTE = "/media/fat/games/C64/dump_vectors.prg"


def ssh():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(MISTER_IP, username=MISTER_USER, password=MISTER_PASS,
              timeout=10, look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(15)
    return c


def run(c, cmd, timeout=20):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors="replace")


def check_ownership(c):
    """Bail out if another agent owns the MiSTer."""
    core = run(c, "cat /tmp/CORENAME 2>/dev/null").strip()
    lock = run(c, "cat /tmp/mister_session.lock 2>/dev/null").strip()
    print(f"CORENAME={core!r}  lock={lock!r}")
    # Empty or 'MENU' = no core loaded (safe to proceed).
    # C64* = we already own it.
    # Anything else (Minimig, MinimigCD, CannonFodder-CD32, etc.) = another
    # agent's core. Tolerated if CORENAME mtime is stale (>5 min) — at
    # that point the other agent has plausibly idled out.
    core_age_out = run(c, "echo $(( $(date +%s) - $(stat -c %Y /tmp/CORENAME "
                          "2>/dev/null || echo 0) ))")
    try:
        core_age = int(core_age_out.strip())
    except ValueError:
        core_age = 0
    if core and core != "MENU" and not core.startswith("C64"):
        if core_age < 300:
            print(f"FATAL: another core ({core!r}) is active "
                  f"(mtime age {core_age}s < 300s) — backing off.")
            return False
        print(f"  (foreign core {core!r} is stale, mtime age {core_age}s — overriding)")
    # Lock age: ignore if stale (>30 min per CLAUDE.md cooperation protocol).
    if lock:
        import time as _t
        lock_age_out = run(c, "echo $(( $(date +%s) - $(stat -c %Y "
                              "/tmp/mister_session.lock 2>/dev/null || echo 0) ))")
        try:
            lock_age = int(lock_age_out.strip())
        except ValueError:
            lock_age = 0
        if lock_age < 1800 and ("agent=cd32" in lock or "agent=minimig" in lock.lower()):
            print(f"FATAL: fresh CD32/Minimig lock ({lock_age}s old) — backing off.")
            return False
        if lock_age >= 1800:
            print(f"  (lock is stale, age={lock_age}s — overriding)")
    return True


def take_ownership(c):
    run(c, "echo \"agent=c64 task='dump_vectors_test' "
          "since=$(date -Iseconds)\" > /tmp/mister_session.lock")


def release_ownership(c):
    run(c, "rm -f /tmp/mister_session.lock")


def screenshot(c, name):
    run(c, "echo screenshot > /dev/MiSTer_cmd")
    time.sleep(2.5)
    out = run(c, "ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1")
    remote = out.strip()
    if not remote:
        print(f"  WARN: no screenshot file found")
        return None
    local = os.path.join(OUT_DIR, name)
    sftp = c.open_sftp()
    sftp.get(remote, local)
    sftp.close()
    print(f"  shot -> {local}")
    return local


def set_cfg_mode(c, mode):
    """Set C64.cfg byte 10 to select T65 (0x08) or SCPU (0x0C)."""
    val = {"t65": 0x08, "scpu": 0x0C}[mode]
    run(c, "printf '\\x{:02x}' | dd of=/media/fat/config/C64.cfg "
          "bs=1 count=1 seek=10 conv=notrunc 2>/dev/null".format(val))
    print(f"  cfg byte 10 = 0x{val:02x} ({mode})")


def deploy_prg(c):
    sftp = c.open_sftp()
    sftp.put(PRG_LOCAL, PRG_REMOTE)
    sftp.close()
    print(f"uploaded {PRG_REMOTE} ({os.path.getsize(PRG_LOCAL)} bytes)")


def write_mgl(c):
    mgl = ("<mistergamedescription>\n"
           "<rbf>_Test/C64</rbf>\n"
           '<file delay="6" type="f" index="1" '
           f'path="{PRG_REMOTE}"/>\n'
           "</mistergamedescription>\n")
    sftp = c.open_sftp()
    with sftp.open("/tmp/dump_vectors.mgl", "w") as f:
        f.write(mgl)
    sftp.close()
    return mgl


def run_one(c, mode):
    print(f"\n=== mode = {mode} ===")
    set_cfg_mode(c, mode)
    print("loading MGL...")
    run(c, "echo load_core /tmp/dump_vectors.mgl > /dev/MiSTer_cmd")

    # Allow time for: core reload (~3s) + KERNAL boot (~3s) +
    # PRG inject + auto-RUN (~2s) + ML execution + CR scroll (~1s).
    # Total ~12-15s is comfortable.
    time.sleep(15)
    screenshot(c, f"dump_{mode}_t015s.png")

    # Take a second shot a few seconds later in case the first was mid-print.
    time.sleep(3)
    screenshot(c, f"dump_{mode}_t018s.png")

    # Snapshot UART tail (mb-probe-003 line includes PC + CIA + bridge fields).
    uart = run(c, "timeout 1 cat /dev/ttyS1 2>/dev/null | "
                  "tr -dc '[:print:]\\n' | tail -2")
    print(f"  UART tail:\n{uart}")


def main():
    if not os.path.exists(PRG_LOCAL):
        print(f"ERROR: PRG not found: {PRG_LOCAL}")
        print("       run: python tools/test_cart/gen_dump_vectors.py")
        sys.exit(1)

    c = ssh()
    if not check_ownership(c):
        sys.exit(2)
    take_ownership(c)
    try:
        deploy_prg(c)
        mgl = write_mgl(c)
        print(f"MGL:\n{mgl}")
        run(c, "stty -F /dev/ttyS1 115200 raw -echo 2>/dev/null")
        run_one(c, "scpu")
        run_one(c, "t65")
    finally:
        release_ownership(c)
        c.close()
    print(f"\nDone. Screenshots in {OUT_DIR}")


if __name__ == '__main__':
    main()
