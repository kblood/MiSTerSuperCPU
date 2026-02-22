# Remote MiSTer Debugging Guide

## SSH/SCP Access Setup

### Quick Connect
```powershell
# SSH to MiSTer console (passwordless - SSH key installed)
ssh root@192.168.50.130

# SCP files from MiSTer
scp root@192.168.50.130:/path/to/file.txt .

# SCP files to MiSTer (upload new .rbf)
scp C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```

### Credentials & Auth
- **IP**: 192.168.50.130
- **Username**: root
- **Password**: 1 (fallback only — SSH key auth is configured)
- **SSH Port**: 22
- **SSH Key**: `~/.ssh/id_ed25519` is authorized on the MiSTer

### Important: MiSTer Root Filesystem
The MiSTer root (`/`) is **read-only by default**. To modify system files:
```bash
ssh root@192.168.50.130 "mount -o remount,rw /"
```

## Key MiSTer Directories

```
/media/fat/                    # Main MiSTer filesystem (SD card, read-write)
  /_Test/                      # Our test cores go here
  /_Computer/                  # Official computer cores
  /_Computers/                 # Older computer cores
  /config/                     # Core configuration (C64.CFG, etc.)
  /games/                      # Game ROMs
/root/                         # Home directory (read-only unless remounted)
```

## Deploying New .rbf Files

```powershell
# From Windows (passwordless):
scp C:\LLM\C64\MiSTerSuperCPU\C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf

# Then on MiSTer: navigate to _Test folder and launch C64 core
# Or if core is already running: use OSD menu to reload
```

## Real-Time Debugging on MiSTer

### Viewing System Logs
```bash
# SSH into MiSTer
ssh root@192.168.50.130

# Tail real-time system messages
tail -f /var/log/messages

# Check kernel dmesg for FPGA load messages
dmesg | tail -50

# Check MiSTer service status
ps aux | grep -i mister
```

### FPGA Load Verification
When you select a new core from MiSTer menu:
```bash
# Watch for FPGA load success (from SSH console, in another terminal)
tail -f /var/log/messages | grep -i fpga

# Or check dmesg
dmesg | tail -20
```

## Advanced Debugging: Register Inspection

If MiSTer exposes FPGA register access (some cores do):
```bash
# Check available debug interfaces
ls -la /sys/bus/platform/devices/

# Memory-mapped register access (if available)
# Read 32-bit value at address: devmem <address> 32
devmem 0x40000000 32
```

## Network File Monitoring

For iterative testing:
```powershell
# PowerShell script to auto-copy .rbf after each build
while($true) {
    if (Test-Path ".\C64.rbf" -NewerThan $lastTime) {
        scp -P 22 .\C64.rbf root@192.168.50.130:/media/fat/cores/C64.rbf
        $lastTime = Get-Date
        Write-Host "Uploaded C64.rbf at $(Get-Date)"
    }
    Start-Sleep -Seconds 2
}
```

## Troubleshooting Connection Issues

| Issue | Solution |
|-------|----------|
| "Connection refused" | Ensure MiSTer is powered on and connected to network |
| "Permission denied" | Verify credentials are `root` / `1` |
| "No route to host" | Check IP address is correct; ping from Windows: `ping 192.168.50.130` |
| Slow transfer speed | Check WiFi signal or use Ethernet adapter if available |
| SSH key prompt | First connection may ask to accept host key; type `yes` |

## Phase 2 Hardware Debugging Workflow

### For Screen Artifact Investigation:
1. **Capture current .rbf that's running**:
   ```bash
   ssh root@192.168.50.130
   ls -la /media/fat/cores/C64.rbf
   ```

2. **Log screen state before/after CPU switch**:
   - Press OSD menu (F12 on keyboard, or button on MiSTer)
   - Enable SuperCPU toggle
   - Note exact timing of screen artifacts
   - Check MiSTer logs for FPGA errors

3. **Revert to Phase 1 if needed** (C64_Phase1_65C816.rbf):
   ```powershell
   scp -P 22 .\C64_Phase1_65C816.rbf root@192.168.50.130:/media/fat/cores/C64.rbf
   ```

4. **Collect debug data**:
   - Take photos/video of screen artifacts
   - Note exact OSD settings when artifacts appear
   - Try with/without resetting core
   - Test with different games/demos if possible

## Next Steps for Phase 3

Once Phase 2 debugging is complete:
1. Fix identified bus contention or synchronization issues
2. Rebuild and test on hardware before proceeding
3. Phase 3 will modify clock domain (sysCycleDef state machine)
4. Use this same remote debugging workflow for iterative refinement
