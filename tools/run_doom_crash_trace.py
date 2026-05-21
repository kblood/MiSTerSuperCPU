#!/usr/bin/env python3
"""
End-to-end test for Doom crash trace capture.

Flow:
  1. Copy freshly built C64.rbf to MiSTer at the dated core path
  2. Reboot MiSTer (OSD F12 menu exit + re-enter) OR just load_rom fresh
  3. Load doom.reu via OSD (manual step or pre-loaded)
  4. Launch Doom (POKE+SYS launcher via mtype)
  5. Capture UART until crash detected (bank $00 BRK loop)
  6. Soft-reset C64 (via OSD reset key — trace preserved by RTL design)
  7. Wait for BASIC READY prompt
  8. mbc load_rom trace_reader.prg
  9. Wait for BASIC to finish printing
 10. Screenshot via mister_debug.py screen
 11. Save output locally

USE: python tools/run_doom_crash_trace.py
Run step-by-step by passing --from-step=N if needed.
"""
import subprocess
import sys
import os
import time
import argparse

MISTER_IP = "192.168.50.130"
LOCAL_RBF = "C64_MiSTer/output_files/C64.rbf"
REMOTE_CORE = "/media/fat/_Computer/C64_20250828.rbf"
TEST_CORE = "/media/fat/_Test/C64.rbf"
REU_PATH = "/media/usb0/C64/doom.reu"
READER_PRG = "/media/usb0/C64/trace_reader.prg"
OUT_DIR = "."

LAUNCHER_LINES = [
    "poke49152,120:poke49153,24:poke49154,251:poke49155,92",
    "poke49156,0:poke49157,0:poke49158,32",
    "sys49152",
]

def sh(cmd, check=True, capture=False):
    print(f"$ {cmd}")
    if capture:
        r = subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True)
        return r.stdout + r.stderr
    else:
        return subprocess.run(cmd, shell=True, check=check)

def deploy_core():
    """Copy the freshly built rbf to both _Test and the dated _Computer location."""
    print("=== DEPLOYING CORE ===")
    sh(f"python tools/mister_debug.py deploy {LOCAL_RBF}")
    # Also copy to the dated path so mbc load_rom maps correctly
    sh(f'python -c "import paramiko; c=paramiko.SSHClient(); '
       f'c.set_missing_host_key_policy(paramiko.AutoAddPolicy()); '
       f'c.connect(\'{MISTER_IP}\', username=\'root\', password=\'1\'); '
       f's=c.open_sftp(); s.put(\'{LOCAL_RBF}\', \'{REMOTE_CORE}\'); s.close(); c.close()"')
    print("Core deployed to both locations.")

def launch_doom():
    """Type the BASIC launcher and SYS into the C64 via mtype."""
    print("=== LAUNCHING DOOM ===")
    keys = r"\r".join(LAUNCHER_LINES)
    sh(f'python tools/mister_debug.py keys "{keys}\\r"')

def capture_crash_uart(duration=180):
    """Stream UART until crash detected or timeout."""
    print(f"=== CAPTURING UART (up to {duration}s) ===")
    log_path = f"{OUT_DIR}/doom_trace_run.log"
    sh(f"python tools/mister_debug.py uart {duration} > {log_path}")
    print(f"UART log: {log_path}")
    return log_path

def detect_crash(log_path):
    """Scan UART log for K:00 BRK loop signature."""
    with open(log_path) as f:
        for line in f:
            if "K:00" in line and "W:FFE6" in line:
                return True
    return False

def soft_reset():
    """Trigger a C64 warm reset via the MiSTer OSD."""
    print("=== SOFT RESET ===")
    # TODO: Use mister_debug.py to send F11 (reset key in MiSTer) or use the reset command
    sh('python tools/mister_debug.py keys "F11"', check=False)
    print("Wait for BASIC READY...")

def load_reader():
    """Inject trace_reader.prg via mbc load_rom."""
    print("=== LOADING READER ===")
    sh(f'python tools/mister_debug.py load_prg {READER_PRG}', check=False)

def capture_screen():
    """Screenshot the final screen showing trace hex dump."""
    print("=== CAPTURING SCREEN ===")
    out = f"{OUT_DIR}/trace_dump.png"
    sh(f"python tools/mister_debug.py screen {out}")
    print(f"Screenshot: {out}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--step", type=int, default=0, help="Start from step N")
    parser.add_argument("--uart-duration", type=int, default=180)
    args = parser.parse_args()

    steps = [
        ("deploy", deploy_core),
        ("launch", launch_doom),
        ("uart", lambda: capture_crash_uart(args.uart_duration)),
        ("reset", soft_reset),
        ("load_reader", load_reader),
        ("screen", capture_screen),
    ]

    for i, (name, fn) in enumerate(steps):
        if i < args.step:
            continue
        print(f"\n--- STEP {i}: {name} ---")
        try:
            fn()
        except Exception as e:
            print(f"Step {name} failed: {e}")
            print(f"Resume with: --step={i}")
            sys.exit(1)

if __name__ == "__main__":
    main()
