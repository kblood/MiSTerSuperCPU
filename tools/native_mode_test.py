#!/usr/bin/env python3
"""Diagnostic tests for native mode + bank $20 fetch on MiSTer SuperCPU.
Runs progressively harder tests to isolate where Doom launch fails."""
import paramiko, time, sys

HOST = "192.168.50.130"
USER = "root"
PASS = "1"

def ssh_exec(client, cmd, timeout=20):
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors='replace')
    err = stderr.read().decode(errors='replace')
    return out, err

def mtype(client, text, extra="enter"):
    escaped = text.replace("'", "'\\''")
    cmd = f"python3 /tmp/mtype.py '{escaped}' {extra}"
    out, err = ssh_exec(client, cmd, timeout=20)
    if err.strip() and 'unmapped' not in err:
        print(f"  mtype err: {err.strip()[:80]}")

def run_test(client, name, pokes, check_cmd, expect=None):
    """Poke machine code, SYS it, then check result."""
    print(f"\n=== TEST: {name} ===")
    for poke_line in pokes:
        mtype(client, poke_line)
        time.sleep(0.8)
    
    # Run
    mtype(client, "SYS49152")
    time.sleep(1.5)
    
    # Check result
    if check_cmd:
        mtype(client, check_cmd)
        time.sleep(1.5)
    
    # Screenshot + UART snapshot
    out, _ = ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo && timeout 2 cat /dev/ttyS1", timeout=5)
    lines = [l for l in out.strip().split('\n') if l.startswith('A:')]
    if lines:
        print(f"  UART: {lines[0][:80]}")
    # Read screen via /dev/MiSTer_cmd screenshot
    return True

def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=10)
    print("[+] Connected to MiSTer")
    
    sftp = client.open_sftp()
    sftp.put("tools/mtype.py", "/tmp/mtype.py")
    sftp.close()
    print("[+] mtype.py uploaded")
    
    ssh_exec(client, "stty -F /dev/ttyS1 115200 raw -echo")
    
    # ---- TEST 1: Basic SYS works (just RTS) ----
    run_test(client, "RTS only (sanity)",
        ["POKE49152,96"],  # RTS
        "PRINT 42")  # Should print 42 if BASIC is OK

    # ---- TEST 2: Native mode round-trip ----
    # CLC, XCE (enter native), SEC, XCE (back to emu), LDA #$42, STA $FB, RTS
    # $C000: 18 FB 38 FB A9 42 85 FB 60
    run_test(client, "Native mode round-trip (CLC+XCE+SEC+XCE+RTS)",
        [
            "POKE49152,24:POKE49153,251:POKE49154,56",   # CLC, XCE, SEC
            "POKE49155,251:POKE49156,169:POKE49157,66",  # XCE, LDA #$42
            "POKE49158,133:POKE49159,251:POKE49160,96",  # STA $FB, RTS
        ],
        "PRINT PEEK(251)")  # Should print 66 ($42)
    
    # ---- TEST 3: Native mode + LDA bank $20 ----
    # SEI, CLC, XCE (native), LDA $200000 (long), SEC, XCE (emu), STA $FB, RTS
    # Bytes: 78 18 FB AF 00 00 20 38 FB 85 FB 60
    run_test(client, "LDA $200000 in native mode",
        [
            "POKE49152,120:POKE49153,24:POKE49154,251",   # SEI CLC XCE
            "POKE49155,175:POKE49156,0:POKE49157,0",      # LDA $200000 (AF 00 00 20)
            "POKE49158,32:POKE49159,56:POKE49160,251",    # SEC XCE
            "POKE49161,133:POKE49162,251:POKE49163,96",   # STA $FB RTS
        ],
        "PRINT PEEK(251)")  # Should print 120 ($78=SEI = first byte of doom)

    # ---- TEST 4: JML $200000 with safe return trampoline ----
    # Write a mini trampoline at $200000 first: SEC($38) XCE($FB) JML $C010($5C $10 $C0 $00)
    # Then at $C010: RTS($60)
    # The SYS at $C000: SEI CLC XCE JML $200000
    # $200000 code: SEC XCE JML $C010 → $C010: LDA #$99 STA $FB RTS
    # 
    # But wait - we can't poke bank $20 from BASIC! That's SDRAM/SuperRAM.
    # So this test only works if we use LDA long to verify, then JML to existing doom code.
    
    # ---- TEST 4b: JML $200000 into doom code ----
    # Doom starts: SEI($78) CLD($D8) CLC($18) XCE($FB) ... 
    # The game will run until it hits something broken. Let's capture UART.
    print("\n=== TEST 4: JML $200000 (into Doom code) ===")
    # Start UART capture
    client.exec_command("timeout 8 cat /dev/ttyS1 > /tmp/uart_test4.log 2>/dev/null &")
    time.sleep(0.3)
    
    # Write loader: SEI CLC XCE JML $200000
    for poke_line in [
        "POKE49152,120:POKE49153,24:POKE49154,251",   # SEI CLC XCE
        "POKE49155,92:POKE49156,0:POKE49157,0:POKE49158,32",  # JML $200000
    ]:
        mtype(client, poke_line)
        time.sleep(0.8)
    
    mtype(client, "SYS49152")
    print("  Waiting 6s for game execution...")
    time.sleep(6.0)
    
    # Read UART
    out, _ = ssh_exec(client, "cat /tmp/uart_test4.log", timeout=5)
    lines = [l.strip() for l in out.strip().split('\n') if l.strip()]
    print(f"  UART lines: {len(lines)}")
    
    # Find transitions
    e_vals = set()
    b_vals = set()
    t_vals = set()
    a_vals = set()
    for l in lines:
        for part in l.split():
            if part.startswith('E:'): e_vals.add(part)
            elif part.startswith('B:'): b_vals.add(part)
            elif part.startswith('T:'): t_vals.add(part)
            elif part.startswith('A:'): a_vals.add(part)
    print(f"  E: {sorted(e_vals)}")
    print(f"  B: {sorted(b_vals)}")
    print(f"  T: {sorted(t_vals)}")
    
    # Show non-idle lines
    non_idle = [l for l in lines if 'E:0' in l or 'B:20' in l]
    if non_idle:
        print("  NATIVE MODE LINES:")
        for l in non_idle[:20]:
            print(f"    {l}")
    else:
        print("  ** No native mode detected in UART **")
    
    # Show transition area
    for i, l in enumerate(lines):
        if l.startswith('A:') and 'T:2' in l and 'T:21' not in l:
            start = max(0, i-3)
            end = min(len(lines), i+5)
            print(f"  Transition at line {i}:")
            for j in range(start, end):
                print(f"    {'>>>' if j == i else '   '} {lines[j]}")
            break
    
    client.close()
    print("\n[+] All tests complete")

if __name__ == '__main__':
    main()
