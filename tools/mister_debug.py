#!/usr/bin/env python3
"""
mister_debug.py - MiSTer FPGA remote debug automation tool

Provides commands for the build-deploy-test loop:
  deploy     - SCP the .rbf to MiSTer and load the core
  load_prg   - Upload and run a PRG file on the test C64 core
  screen     - Take and retrieve a screenshot
  osd_screen - Open OSD, take a screenshot (captures OSD overlay), then close OSD
  uart       - Read debug UART output from /dev/ttyS1
  keys       - Send keyboard input
  reboot     - Reboot the MiSTer
  status     - Check if MiSTer is reachable and what core is running

Usage:
  python tools/mister_debug.py deploy [rbf_path]
  python tools/mister_debug.py load_prg <prg_file>
  python tools/mister_debug.py screen [output_path]
  python tools/mister_debug.py osd_screen [output_path]
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
PASS = os.environ.get("MISTER_PASS", "1")
DEST = os.environ.get("MISTER_DEST", "/media/fat/_Test/C64.rbf")
DEFAULT_RBF = "C64_MiSTer/output_files/C64.rbf"
SCREENSHOT_DIR = "/media/fat/screenshots"

try:
    import paramiko
    HAS_PARAMIKO = True
except ImportError:
    HAS_PARAMIKO = False

def _get_ssh_client():
    """Create a paramiko SSH client connected to MiSTer."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=5)
    return client

def ssh(cmd, timeout=10):
    """Run a command on MiSTer via SSH."""
    if HAS_PARAMIKO:
        try:
            client = _get_ssh_client()
            stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
            out = stdout.read().decode().strip()
            err = stderr.read().decode().strip()
            rc = stdout.channel.recv_exit_status()
            client.close()
            return out, err, rc
        except Exception as e:
            return "", str(e), 1
    # Fallback to ssh command
    full_cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
                f"{USER}@{HOST}", cmd]
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", "SSH timeout", 1

def scp_to(local, remote):
    """Copy a file to MiSTer."""
    if HAS_PARAMIKO:
        try:
            client = _get_ssh_client()
            sftp = client.open_sftp()
            sftp.put(local, remote)
            sftp.close()
            client.close()
            return True
        except Exception as e:
            print(f"SFTP upload error: {e}")
            return False
    cmd = ["scp", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
           local, f"{USER}@{HOST}:{remote}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return result.returncode == 0

def scp_from(remote, local):
    """Copy a file from MiSTer."""
    if HAS_PARAMIKO:
        try:
            client = _get_ssh_client()
            sftp = client.open_sftp()
            sftp.get(remote, local)
            sftp.close()
            client.close()
            return True
        except Exception as e:
            print(f"SFTP download error: {e}")
            return False
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

def cmd_load_prg(args):
    """Upload a PRG file to MiSTer and inject it into the running C64 core.

    Uses mbc load_rom to inject the PRG without reloading the core.
    This preserves UART, overlay, and turbo mode (MGL loading kills these).

    The core must already be running (via deploy). If not, deploy is done first.
    After injection, the PRG is in RAM but not auto-run. Use SYS 2061 for
    ca65 PRGs (c64-816.cfg layout) or RUN for BASIC programs.

    Note: mbc load_rom corrupts the BASIC stub, so RUN may not work.
    Machine code PRGs should use SYS <start_address>.
    """
    if not args:
        print("Usage: load_prg <prg_file>")
        print("  Uploads the PRG to MiSTer and injects it into the running core.")
        print("  Use SYS 2061 to execute ca65 PRGs, or RUN for BASIC programs.")
        print("  Example: python tools/mister_debug.py load_prg test.prg")
        return 1

    prg_local = args[0]
    if not os.path.exists(prg_local):
        print(f"Error: {prg_local} not found")
        return 1

    prg_name = os.path.basename(prg_local)
    prg_remote = f"/media/fat/games/C64/{prg_name}"

    size = os.path.getsize(prg_local)
    print(f"Uploading {prg_local} ({size:,} bytes) to {HOST}:{prg_remote}")

    if not scp_to(prg_local, prg_remote):
        print("Error: SCP failed")
        return 1
    print("Upload complete.")

    # Check if core is running by reading UART
    print("Checking if core is running...")
    out, _, rc = ssh('stty -F /dev/ttyS1 115200 raw -echo; timeout 1 cat /dev/ttyS1 2>/dev/null | head -1',
                     timeout=5)
    if not out:
        print("Core not running or UART not active. Deploying...")
        if not os.path.exists(DEFAULT_RBF):
            print(f"Error: {DEFAULT_RBF} not found. Deploy manually first.")
            return 1
        rc = cmd_deploy([])
        if rc != 0:
            return rc
        # Wait for boot and verify UART
        time.sleep(3)
        out, _, _ = ssh('timeout 2 cat /dev/ttyS1 2>/dev/null | head -1', timeout=5)
        if not out:
            print("Warning: UART still not active after deploy")

    # Inject PRG via mbc load_rom (preserves UART/overlay/turbo)
    print(f"Injecting {prg_name} via mbc load_rom...")
    out, err, rc = ssh(f'mbc load_rom 1 {prg_remote}', timeout=10)
    if rc != 0:
        print(f"Error: mbc load_rom failed: {err}")
        return 1

    time.sleep(2)
    print(f"PRG injected. Use SYS 2061 (ca65) or RUN (BASIC) to execute.")
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

MTYPE_REMOTE = "/tmp/mtype.py"
MTYPE_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mtype.py")

def _ensure_mtype():
    """Upload mtype.py to MiSTer if not already there."""
    out, _, rc = ssh(f'test -f {MTYPE_REMOTE} && echo ok')
    if 'ok' not in (out or ''):
        print("Uploading mtype.py to MiSTer...")
        if not scp_to(MTYPE_LOCAL, MTYPE_REMOTE):
            print("Error: failed to upload mtype.py")
            return False
    return True

def _send_keys_mtype(keys_args):
    """Send keys via mtype.py on MiSTer. keys_args is a string of mtype arguments."""
    if not _ensure_mtype():
        return False
    # mtype.py takes ~6s for uinput device settle, then sends keys quickly
    out, err, rc = ssh(f'python3 {MTYPE_REMOTE} {keys_args}', timeout=15)
    if rc != 0:
        print(f"mtype.py error: {err}")
        return False
    return True

def _capture_obs_window(output_path):
    """Capture the OBS window via PIL ImageGrab (multi-monitor aware).

    Returns True if OBS was found and captured, False otherwise.
    """
    try:
        import ctypes
        from PIL import ImageGrab
        import subprocess

        # Find OBS window handle
        r = subprocess.run(['powershell', '-c', '(Get-Process obs64 -ErrorAction SilentlyContinue).MainWindowHandle'],
                           capture_output=True, text=True, timeout=5)
        hwnd = int(r.stdout.strip()) if r.stdout.strip() else 0
        if not hwnd:
            return False

        # Get window rect
        class RECT(ctypes.Structure):
            _fields_ = [('left', ctypes.c_long), ('top', ctypes.c_long),
                        ('right', ctypes.c_long), ('bottom', ctypes.c_long)]

        user32 = ctypes.windll.user32
        rect = RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))

        # Get virtual screen origin for coordinate mapping
        virt_left = user32.GetSystemMetrics(76)   # SM_XVIRTUALSCREEN
        virt_top = user32.GetSystemMetrics(77)     # SM_YVIRTUALSCREEN

        # Grab all screens and crop to OBS window
        img = ImageGrab.grab(all_screens=True)
        crop_box = (rect.left - virt_left, rect.top - virt_top,
                    rect.right - virt_left, rect.bottom - virt_top)
        cropped = img.crop(crop_box)
        cropped.save(output_path)
        return True
    except Exception as e:
        print(f"OBS capture failed: {e}")
        return False

def cmd_osd_screen(args):
    """Open the OSD, take a screenshot (capturing OSD overlay), then close OSD.

    MiSTer's built-in screenshot commands capture the FPGA video output BEFORE
    the OSD overlay is composited in the hardware video pipeline. Neither
    'screenshot' nor 'screenshot scaled' will include the OSD.

    To capture the OSD, this tool uses OBS Studio + HDMI capture device:
    1. Opens OSD via mtype.py (uinput — the only working method)
    2. Captures the OBS preview window via PIL ImageGrab
    3. Falls back to MiSTer screenshot if OBS is unavailable (no OSD in capture)
    """
    output = args[0] if args else "mister_osd_screen.png"

    # Step 1: Open OSD (F12 via mtype.py uinput)
    print("Opening OSD (F12 via mtype.py)...")
    if not _send_keys_mtype('f12'):
        print("Error: could not send F12")
        return 1

    # Step 2: Wait for OSD to render
    time.sleep(1)

    # Step 3: Try OBS window capture (includes OSD overlay)
    print("Capturing OBS window (HDMI output with OSD)...")
    if _capture_obs_window(output):
        print(f"OSD screenshot saved to {output} (via OBS HDMI capture)")
        return 0

    # Step 4: Fallback — MiSTer screenshot (will NOT include OSD)
    print("OBS not available, falling back to MiSTer screenshot (no OSD in capture)...")
    ssh('echo "screenshot" > /dev/MiSTer_cmd')
    time.sleep(1.5)

    # Step 5: Close OSD
    print("Closing OSD...")
    _send_keys_mtype('f12')

    # Step 6: Find and retrieve the latest screenshot
    out, err, rc = ssh(f'ls -t {SCREENSHOT_DIR}/*/*.png 2>/dev/null | head -1')
    if rc != 0 or not out:
        print("Error: No screenshots found")
        return 1

    remote_path = out.strip()
    print(f"Retrieving {remote_path}...")

    if scp_from(remote_path, output):
        print(f"Screenshot saved to {output} (core video only — no OSD)")
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
    """Send keyboard input via mtype.py (uinput) on MiSTer.

    Translates mbc-style shorthand to mtype.py arguments for convenience.
    Also accepts mtype.py native arguments directly.
    """
    if not args:
        print("Usage: keys <sequence_or_mtype_args>")
        print("  Shorthand: M=F12/OSD, U=Up, D=Down, L=Left, R=Right, O=Enter, E=Escape")
        print("  Or mtype.py args: f12 down down down enter")
        return 1

    seq = args[0]

    # Check if it looks like mbc shorthand (single uppercase letters)
    MBC_TO_MTYPE = {'M': 'f12', 'U': 'up', 'D': 'down', 'L': 'left',
                    'R': 'right', 'O': 'enter', 'E': 'esc', 'H': 'home', 'F': 'end'}
    if all(c in MBC_TO_MTYPE for c in seq):
        mtype_args = ' '.join(MBC_TO_MTYPE[c] for c in seq)
        print(f"Sending key sequence: {seq} → mtype.py {mtype_args}")
    else:
        # Pass through as mtype.py arguments
        mtype_args = ' '.join(args)
        print(f"Sending keys: {mtype_args}")

    if _send_keys_mtype(mtype_args):
        return 0

    # Fallback to mbc
    print("mtype.py failed, trying mbc raw_seq fallback...")
    if all(c in MBC_TO_MTYPE for c in seq):
        out, err, rc = ssh(f'mbc raw_seq "{seq}"')
        return rc
    print("Cannot fall back to mbc for non-shorthand input")
    return 1

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
        "deploy":     cmd_deploy,
        "load_prg":   cmd_load_prg,
        "screen":     cmd_screen,
        "osd_screen": cmd_osd_screen,
        "uart":       cmd_uart,
        "keys":       cmd_keys,
        "reboot":     cmd_reboot,
        "status":     cmd_status,
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
