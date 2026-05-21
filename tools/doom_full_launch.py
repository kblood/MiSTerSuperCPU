#!/usr/bin/env python3
"""Load doom.reu via OSD, then launch with UART capture at the crash moment.
Captures UART DURING the transition from BASIC to native mode."""
import paramiko, time, sys, threading

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
    
    # Step 1: Load doom.reu via OSD
    print("[+] Loading doom.reu via OSD...")
    # Open OSD (F12)
    mtype(client, "f12", extra="")
    time.sleep(1)
    # Navigate to "Load REU *.REU" (4x down + enter)
    mtype(client, "down", extra="")
    time.sleep(0.3)
    mtype(client, "down", extra="")
    time.sleep(0.3)
    mtype(client, "down", extra="")
    time.sleep(0.3)
    mtype(client, "down", extra="")
    time.sleep(0.3)
    mtype(client, "enter", extra="")
    time.sleep(1)
    # doom.reu should be at cursor - press enter
    mtype(client, "enter", extra="")
    print("[+] Waiting 12s for doom.reu load...")
    time.sleep(12)
    
    # Verify doom.reu loaded: check first byte
    print("[+] Verifying doom.reu data at bank $20...")
    mtype(client, "POKE49152,175:POKE49153,0:POKE49154,0")  # AF 00 00 20 = LDA $200000
    time.sleep(0.8)
    mtype(client, "POKE49155,32:POKE49156,133:POKE49157,251")  # STA $FB, 
    time.sleep(0.8) 
    mtype(client, "POKE49158,96")  # RTS
    time.sleep(0.8)
    mtype(client, "SYS49152:PRINT PEEK(251)")
    time.sleep(2)
    
    # Step 2: Poke the skip loader
    # SEI, LDA #$7F, STA $DD0D, LDA $DD0D, CLC, XCE, JML $200000
    # Bytes: 78 A9 7F 8D 0D DD AD 0D DD 18 FB 5C 00 00 20
    print("[+] Poking skip loader (SEI+CIA2_NMI_off+CLC+XCE+JML)...")
    mtype(client, "POKE49152,120:POKE49153,169:POKE49154,127")  # SEI, LDA #$7F
    time.sleep(0.8)
    mtype(client, "POKE49155,141:POKE49156,13:POKE49157,221")   # STA $DD0D
    time.sleep(0.8)
    mtype(client, "POKE49158,173:POKE49159,13:POKE49160,221")   # LDA $DD0D (ack)
    time.sleep(0.8)
    mtype(client, "POKE49161,24:POKE49162,251")                  # CLC, XCE
    time.sleep(0.8)
    mtype(client, "POKE49163,92:POKE49164,0:POKE49165,0:POKE49166,32")  # JML $200000
    time.sleep(0.8)

    # Step 3: Start UART capture with longer duration, then launch
    print("[+] Starting UART capture...")
    client.exec_command("timeout 20 cat /dev/ttyS1 > /tmp/uart_doom2.log 2>/dev/null &")
    time.sleep(0.5)
    
    print("[+] Launching SYS49152...")
    mtype(client, "SYS49152")
    
    # Wait for crash or game to run
    print("[+] Waiting 15s...")
    time.sleep(15)
    
    # Step 4: Capture final state + UART
    print("[+] Reading UART capture...")
    out, _ = ssh_exec(client, "cat /tmp/uart_doom2.log", timeout=10)
    lines = [l.strip() for l in out.strip().split('\n') if l.strip() and l.startswith('A:')]
    print(f"Total UART lines: {len(lines)}")
    
    # Find all unique states
    e_vals = set()
    b_vals = set()
    t_vals = set()
    a_addrs = []
    for l in lines:
        for part in l.split():
            if part.startswith('E:'): e_vals.add(part)
            elif part.startswith('B:'): b_vals.add(part)
            elif part.startswith('T:'): t_vals.add(part)
            elif part.startswith('A:'): a_addrs.append(part)
    
    print(f"E values: {sorted(e_vals)}")
    print(f"B values: {sorted(b_vals)}")
    print(f"T values: {sorted(t_vals)}")
    
    # Find transition from idle (T:21) to game state
    prev_idle = True
    transitions = []
    for i, l in enumerate(lines):
        is_idle = 'T:21' in l and ('A:E5CE' in l or 'A:E5D3' in l)
        if prev_idle and not is_idle:
            # Transition found! Show context
            start = max(0, i-2)
            end = min(len(lines), i+20)
            transitions.append((i, start, end))
        prev_idle = is_idle
    
    for tidx, (i, start, end) in enumerate(transitions):
        print(f"\n=== TRANSITION {tidx+1} at line {i} ===")
        for j in range(start, end):
            marker = '>>>' if j == i else '   '
            print(f"  {marker} [{j:4d}] {lines[j]}")
    
    # Show last 10 lines
    print(f"\n=== LAST 10 LINES ===")
    for l in lines[-10:]:
        print(f"  {l}")
    
    # Show unique addresses in non-idle lines  
    native_lines = [l for l in lines if 'E:0' in l]
    if native_lines:
        print(f"\n=== NATIVE MODE ({len(native_lines)} lines) ===")
        for l in native_lines[:30]:
            print(f"  {l}")
    
    client.close()
    print("\n[+] Done")

if __name__ == '__main__':
    main()
