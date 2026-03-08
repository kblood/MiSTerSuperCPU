#!/usr/bin/env python3
"""
mister_debug.py - MiSTer FPGA remote debug automation tool

Provides commands for the build-deploy-test loop:
  deploy   - SCP the .rbf to MiSTer and load the core
  screen   - Take and retrieve a screenshot
  uart     - Read debug UART output from /dev/ttyS1
  keys     - Send keyboard input
  reboot   - Reboot the MiSTer
  status   - Check if MiSTer is reachable and what core is running

Usage:
  python tools/mister_debug.py deploy [rbf_path]
  python tools/mister_debug.py screen [output_path]
  python tools/mister_debug.py uart [seconds]
  python tools/mister_debug.py keys <key_sequence>
  python tools/mister_debug.py reboot
  python tools/mister_debug.py status

Environment variables:
  MISTER_HOST  - MiSTer IP/hostname (default: 192.168.50.130)
  MISTER_USER  - SSH user (default: root)
  MISTER_DEST  - Core deployment path (default: /media/fat/_Test/C64.rbf)
"""

import subprocess
import sys
import os
import time
import glob
from pathlib import Path

# Configuration
HOST = os.environ.get("MISTER_HOST", "192.168.50.130")
USER = os.environ.get("MISTER_USER", "root")
DEST = os.environ.get("MISTER_DEST", "/media/fat/_Test/C64.rbf")
DEFAULT_RBF = "C64_MiSTer/output_files/C64.rbf"
SCREENSHOT_DIR = "/media/fat/screenshots"

def ssh(cmd, timeout=10):
    """Run a command on MiSTer via SSH."""
    full_cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
                f"{USER}@{HOST}", cmd]
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", "SSH timeout", 1

def scp_to(local, remote):
    """Copy a file to MiSTer."""
    cmd = ["scp", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
           local, f"{USER}@{HOST}:{remote}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return result.returncode == 0

def scp_from(remote, local):
    """Copy a file from MiSTer."""
    cmd = ["scp", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
           f"{USER}@{HOST}:{remote}", local]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return result.returncode == 0

def cmd_deploy(args):
    """Deploy .rbf to MiSTer and load it."""
    rbf = args[0] if args else DEFAULT_RBF
    if not os.path.exists(rbf):
        print(f"Error: {rbf} not found")
        return 1

    size = os.path.getsize(rbf)
    print(f"Deploying {rbf} ({size:,} bytes) to {HOST}:{DEST}")

    if not scp_to(rbf, DEST):
        print("Error: SCP failed")
        return 1
    print("Upload complete.")

    # Load the core
    print("Loading core...")
    out, err, rc = ssh(f'echo "load_core {DEST}" > /dev/MiSTer_cmd')
    if rc != 0:
        print(f"Warning: load_core command returned {rc}: {err}")
    else:
        print("Core load command sent. Waiting for boot...")

    time.sleep(5)
    print("Core should be running now.")
    return 0

def cmd_screen(args):
    """Take a screenshot and retrieve it."""
    output = args[0] if args else "mister_screen.png"

    # Trigger screenshot
    print("Taking screenshot...")
    ssh('echo "screenshot" > /dev/MiSTer_cmd')
    time.sleep(1.5)

    # Find the latest screenshot
    out, err, rc = ssh(f'ls -t {SCREENSHOT_DIR}/*/*.png 2>/dev/null | head -1')
    if rc != 0 or not out:
        print("Error: No screenshots found")
        return 1

    remote_path = out.strip()
    print(f"Retrieving {remote_path}...")

    if scp_from(remote_path, output):
        print(f"Screenshot saved to {output}")
        return 0
    else:
        print("Error: Failed to retrieve screenshot")
        return 1

def cmd_uart(args):
    """Read debug UART output."""
    seconds = int(args[0]) if args else 3
    print(f"Reading debug UART for {seconds}s...")
    out, err, rc = ssh(f'timeout {seconds} cat /dev/ttyS1 2>/dev/null || true',
                       timeout=seconds + 5)
    if out:
        print(out)
    else:
        print("(no UART output received - is Debug UART enabled in OSD?)")
    return 0

def cmd_keys(args):
    """Send keyboard input via mbc raw_seq."""
    if not args:
        print("Usage: keys <sequence>")
        print("  M=F12/OSD, U=Up, D=Down, L=Left, R=Right, O=Enter, E=Escape")
        return 1
    seq = args[0]
    print(f"Sending key sequence: {seq}")
    out, err, rc = ssh(f'mbc raw_seq "{seq}"')
    if rc != 0:
        # mbc might not be installed, try alternative
        print(f"mbc not available ({err}), trying /dev/MiSTer_cmd...")
        # Can't do raw_seq via MiSTer_cmd, but we can suggest
        print("Install mbc for key input support")
    return rc

def cmd_reboot(args):
    """Reboot the MiSTer."""
    print(f"Rebooting {HOST}...")
    ssh("reboot")
    print("Reboot command sent.")
    return 0

def cmd_status(args):
    """Check MiSTer status."""
    out, err, rc = ssh("uptime")
    if rc != 0:
        print(f"MiSTer at {HOST} is unreachable")
        return 1
    print(f"MiSTer at {HOST}: {out}")

    # Check what core is running
    out2, _, _ = ssh("cat /tmp/ACTIVE_CORE 2>/dev/null || echo unknown")
    print(f"Active core: {out2}")

    # Check if debug UART is producing output
    out3, _, _ = ssh("timeout 1 cat /dev/ttyS1 2>/dev/null | head -1 || true", timeout=5)
    if out3:
        print(f"Debug UART active: {out3}")
    else:
        print("Debug UART: no output (may be disabled)")

    return 0

def main():
    commands = {
        "deploy": cmd_deploy,
        "screen": cmd_screen,
        "uart":   cmd_uart,
        "keys":   cmd_keys,
        "reboot": cmd_reboot,
        "status": cmd_status,
    }

    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        print("Commands:", ", ".join(commands.keys()))
        return 0

    cmd = sys.argv[1]
    if cmd not in commands:
        print(f"Unknown command: {cmd}")
        print("Commands:", ", ".join(commands.keys()))
        return 1

    return commands[cmd](sys.argv[2:])

if __name__ == "__main__":
    sys.exit(main())
