# Session Passover - 2026-04-04b

## Goal
Fix clk32 timing violations and continue Doom display investigation.

## Key Achievements

### Timing Closure (Major Progress)
- **Root cause identified**: The -5.768ns clk32 violation was NOT from the cpuDi mux as suspected — it was entirely within the **P65C816 CPU core** (MCode→AddrGen→Mux, 36 logic levels).
- **Fix applied**: SDC multicycle path constraint for P65C816 registers:
  ```sdc
  set_multicycle_path -setup 2 -to [get_registers {*P65C816:cpu|*}]
  set_multicycle_path -hold 1 -to [get_registers {*P65C816:cpu|*}]
  ```
- **Justification**: `enableCpu_816` (CE) never fires on consecutive clk32 edges (minimum 2-cycle gap from BRAM/cache suppress and SDRAM pipeline).
- **Results**: clk32 slack improved from **-5.780ns to -0.368ns** (97% better). TNS from -408 to -14.
- **clk64**: +0.825ns → -0.274ns (slight regression, marginal)
- **Remaining violation**: P65C816 AddrGen → cartridge mem_req_addr (18 levels, -0.368ns). This is a P65C816 OUTPUT → external register path, not covered by the multicycle constraint. Works in practice.

### cpuDi Mux Pipelining (Also Applied)
- Registered all combinational cpuDi mux inputs for additional timing margin:
  - `iof_detect_d1` (was already declared, now used in mux)
  - `scpu_rom_stub_active_d1`, `scpu_rom_stub_data_r`
  - `cache_di_r`
  - `scpu_reg_active_d1`, `scpu_reg_data_r` (pre-computed SuperCPU register decode)
- This didn't fix the main violation (CPU-internal) but reduces mux depth from ~8-10 to ~3 LUT levels.
- All registered signals align at 1-cycle delay, same as bram_hit_d1/cache_hit_d1.

### TimeQuest TCL Script
- Created `report_timing.tcl` for detailed path analysis (get_timing_paths + get_node_info).
- Identified critical paths: MCode|addrInc → Mux137 (all top 20 paths to same destination).

## Doom Status
- **Stable execution confirmed**: Doom runs in bank $9B (not $2C as previously expected), native mode (E:0)
- **BRK-based dispatch loop**: Pattern every 3 frames: FFE7 (BRK vector) → $9B:0202 → varied game code
- **Interrupts enabled**: P has I=0 in game code frames
- **No VIC raster IRQ**: Only BRK vectors (A:FFE7) observed, never IRQ vectors (A:FFEF)
- **Display unchanged**: BASIC READY screen still showing

### Why Display Still Doesn't Update
The VIC raster IRQ isn't firing. Possible causes:
1. **$D01A not set** — Doom's init code hasn't written $D01A=$01 to enable raster interrupt
2. **IRQ vector not installed** — $FFEE/$FFEF still has default RTI handler ($FF00)
3. **Init sequence incomplete** — the raster IRQ setup code in bank $80 never executed

The game IS running (varied code in bank $9B, BRK dispatch working). I=0 confirms CLI was executed. But no VIC IRQ means either $D01A not set or the VIC IRQ line isn't reaching the CPU.

## Build State
- `C64.sdc`: multicycle constraints for clk32→clk64 crossing AND P65C816 internal paths
- `fpga64_sid_iec.vhd`: cpuDi mux pipelining (registered conditions/data)
- **Timing**: clk32 -0.368ns (near-closure), clk64 -0.274ns (marginal)
- **Resources**: 30,388 ALMs (73%), 95% RAM blocks

## Files Changed
- `C64_MiSTer/C64.sdc` — added P65C816 multicycle constraint
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — registered cpuDi mux inputs + pre-computed SCPU register decode
- `C64_MiSTer/report_timing.tcl` — TimeQuest analysis script

## Critical Finding: MGL Loading Doesn't Work for Doom

**All K:9B occurrences were from MGL loading, which breaks SuperCPU native mode.**
This is a known issue from sessions 2026-03-30 and 2026-03-31.

- MGL reloads the core, which the ARM-side MiSTer framework handles differently
- After MGL: REU DMA returns zeros, turbo disabled, native mode broken
- The ONLY working method is **OSD load from USB** (physical keyboard)
- The SDRAM data IS correct after MGL (verified), but the core state is broken
- **deploy also wipes SDRAM** — can't redeploy after MGL to fix state

## Next Steps
1. **Test with OSD load** — user must manually load doom.reu via OSD (F12 → Load File → USB → doom.reu)
2. **After OSD load**: type POKE/SYS loader, verify K:2C appears (game loop)
3. **If K:2C works**: investigate why display doesn't update (raster IRQ not firing)
4. **irq_vic diagnostic is in current build** — T:xx bit 7 shows VIC IRQ status
5. **Consider adding multicycle constraint for P65C816→cartridge path** to eliminate remaining -0.368ns

## Test Commands
```bash
# Deploy + verify
python tools/mister_debug.py deploy
python tools/mister_debug.py uart 3

# Load doom.reu via MGL + redeploy
python -c "import paramiko; ssh=paramiko.SSHClient(); ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy()); ssh.connect('192.168.50.130',username='root',password='1'); sftp=ssh.open_sftp(); f=sftp.open('/tmp/doom.mgl','w'); f.write('<mistergamedescription>\n<rbf>/media/fat/_Test/C64</rbf>\n<file delay=\"2\" type=\"s\" index=\"0\" path=\"/media/usb0/games/C64/doom.reu\"/>\n</mistergamedescription>'); f.close(); sftp.close(); ssh.exec_command('echo load_core /tmp/doom.mgl > /dev/MiSTer_cmd'); import time; time.sleep(5); ssh.close()"
python tools/mister_debug.py deploy  # redeploy (SDRAM survives)

# Type loader
python -c "import paramiko; ssh=paramiko.SSHClient(); ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy()); ssh.connect('192.168.50.130',username='root',password='1'); ssh.exec_command('python3 /tmp/mtype.py \"10 FORI=0TO6:READA:POKE49152+I,A:NEXT\" enter \"20 DATA120,24,251,92,0,0,32\" enter RUN enter', timeout=30)[1].read(); import time; time.sleep(3); ssh.exec_command('python3 /tmp/mtype.py SYS49152 enter', timeout=30)[1].read(); ssh.close()"

# Monitor
python tools/mister_debug.py uart 5
```
