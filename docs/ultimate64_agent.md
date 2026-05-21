# Ultimate 64 Debug Agent Reference

## Purpose
Provides instructions for controlling and testing the Ultimate 64 (Elite) via its REST API.
Use this for comparing SuperCPU behavior between MiSTer and real Ultimate 64 hardware.

## Connection Details
- Ultimate 64 IP: 192.168.50.94
- API base: `http://192.168.50.94/v1`
- Firmware requirement: 3.11+ for REST API support
- No authentication required

## Discovery
Find the U64 on the network:
```bash
# Scan subnet for U64 REST API
for i in $(seq 1 254); do
  (curl -s --connect-timeout 0.5 "http://192.168.50.$i/v1/version" 2>/dev/null | grep -q "version" && echo "FOUND: 192.168.50.$i") &
done; wait
```

## API Quick Reference

### Version Check
```bash
curl http://192.168.50.94/v1/version
```

### Machine Control
```bash
# Reset the C64
curl -X PUT http://192.168.50.94/v1/machine:reset

# Reboot (full reinit with cartridge)
curl -X PUT http://192.168.50.94/v1/machine:reboot

# Pause (DMA hold)
curl -X PUT http://192.168.50.94/v1/machine:pause

# Resume
curl -X PUT http://192.168.50.94/v1/machine:resume

# Power off
curl -X PUT http://192.168.50.94/v1/machine:poweroff
```

### Load and Run Programs
```bash
# Run a PRG file already on the U64 filesystem
curl -X PUT "http://192.168.50.94/v1/runners:run_prg?file=/path/on/u64/test.prg"

# Upload and run a PRG directly (binary POST)
curl -X POST --data-binary @speedtest.prg http://192.168.50.94/v1/runners:run_prg

# Load PRG into memory without running
curl -X POST --data-binary @test.prg http://192.168.50.94/v1/runners:load_prg

# Run a CRT cartridge from U64 filesystem
curl -X PUT "http://192.168.50.94/v1/runners:run_crt?file=/path/on/u64/test.crt"

# Upload and run a CRT directly (binary POST)
curl -X POST --data-binary @scpu_speedtest.crt http://192.168.50.94/v1/runners:run_crt
```

### Memory Access (DMA)
```bash
# Read 256 bytes from $0400 (screen RAM)
curl "http://192.168.50.94/v1/machine:readmem?address=0400&length=100"

# Write bytes to memory
curl -X PUT "http://192.168.50.94/v1/machine:writemem?address=0400&data=01020304"

# Write binary data to address
curl -X POST --data-binary @data.bin "http://192.168.50.94/v1/machine:writemem?address=C000"
```

### Debug Register ($D7FF, U64 only)
```bash
# Read debug register
curl http://192.168.50.94/v1/machine:debugreg

# Write debug register
curl -X PUT "http://192.168.50.94/v1/machine:debugreg?value=01"
```

### Configuration
```bash
# List all config categories
curl http://192.168.50.94/v1/configs

# List items in a category
curl http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings

# Get a specific setting
curl "http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings/SpeedDos%20Parallel%20Cable"

# Set a value
curl -X PUT "http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings/CPU%20Speed?value=48%20MHz"
```

### Drive Control
```bash
# Mount a D64 disk image
curl -X PUT "http://192.168.50.94/v1/drives/A:mount?image=/path/to/disk.d64"

# Remove disk
curl -X PUT http://192.168.50.94/v1/drives/A:remove
```

### Data Streams (U64 only)
```bash
# Start video stream to your IP
curl -X PUT "http://192.168.50.94/v1/streams/video:start?ip=192.168.2.YYY"

# Start debug stream
curl -X PUT "http://192.168.50.94/v1/streams/debug:start?ip=192.168.2.YYY"

# Stop streams
curl -X PUT http://192.168.50.94/v1/streams/video:stop
curl -X PUT http://192.168.50.94/v1/streams/debug:stop
```

## Speed Test Notes

### scpu_speedtest.crt on Ultimate 64
The speedtest CRT shows only 0.9-1.1 MHz on the U64, even in 64MHz turbo mode.
This is because the CRT uses SuperCPU registers ($D07A/$D07B) to switch speed modes,
which the U64 does not implement. The U64's turbo is controlled via its own config:

```bash
# Check U64 CPU speed setting
curl "http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings/CPU%20Speed"

# Set U64 to different speeds (check available values first)
curl -X PUT "http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings/CPU%20Speed?value=1%20MHz"
curl -X PUT "http://192.168.50.94/v1/configs/C64%20and%20Cartridge%20Settings/CPU%20Speed?value=48%20MHz"
```

To properly benchmark the U64, the speedtest would need a variant that:
1. Does NOT write $D07A/$D07B (those are no-ops on U64)
2. Just measures the counting loop speed at whatever the current CPU speed is
3. Or uses the REST API to switch speed between measurements

### Comparison Workflow: MiSTer vs Ultimate 64
```bash
# 1. Deploy CRT to both platforms
scp tools/test_cart/out/scpu_speedtest.crt root@192.168.50.130:/media/usb0/games/C64/
curl -X POST --data-binary @tools/test_cart/out/turbo_test.crt http://192.168.50.94/v1/runners:run_crt

# 2. On MiSTer: reload core and run test
ssh root@192.168.50.130 "echo 'load_core /media/fat/_Test/C64.rbf' > /dev/MiSTer_cmd"

# 3. On U64: reset and read screen RAM to check results
curl -X PUT http://192.168.50.94/v1/machine:reset
sleep 3
curl "http://192.168.50.94/v1/machine:readmem?address=0400&length=03E8"
```

## Deploy Test CRTs to Ultimate 64
```bash
# Upload and immediately run a test CRT
curl -X POST --data-binary @tools/test_cart/out/scpu_speedtest.crt http://192.168.50.94/v1/runners:run_crt

# Upload and run turbo test
curl -X POST --data-binary @tools/test_cart/out/turbo_test.crt http://192.168.50.94/v1/runners:run_crt

# Upload and run dead test
curl -X POST --data-binary @tools/test_cart/out/scpu_dead_test.crt http://192.168.50.94/v1/runners:run_crt
```

## Reading Screen RAM for Automated Test Verification
The U64 can read screen RAM via DMA, enabling automated test result parsing:
```bash
# Read screen RAM (1000 bytes = 40x25)
curl "http://192.168.50.94/v1/machine:readmem?address=0400&length=03E8"
```
This returns binary data. Parse PETSCII screen codes to extract test results
(hex digits, pass/fail indicators) without needing visual inspection.
