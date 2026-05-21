# Session Passover — 2026-03-27

## What Was Done
Fixed REU register reads/writes — 100% reliable from interactive BASIC (5/5 boots).

### Root Causes Found
1. **IOF_raw timing violation**: cpuAddr_pre → iof_detect → IOF_raw has -10ns slack. IOF_raw NEVER samples '1' at clock edges. Proven: `if (IOF_raw) $42 else $AA` always returns $AA.
2. **3-stage IOF pipeline alignment**: `enableCpu` and `io_in_pipeline` never both '1' at the same edge in turbo mode.
3. **c64_addr unreliable**: `wb_drain_active` overrides `ramAddr` with `wb_addr`, making `reu_oe='0'`.
4. **REU edge detection broken**: Same IOF_raw timing violation prevents `~old_cs & cpu_cs` from firing.

### Solution (commit 544f317)
- **cpuDi mux**: `io_data when (iof_detect = '1' and cpuWe_pre = '0')` — direct combinational path works because iof_detect feeds combinational logic (not FF D-input)
- **REU register bypass mux**: Exposed REU registers (status, cmd, addr_c64, addr_ram, length) via new output ports. Combinational mux in c64.sv reads by `dbg_cpu_addr[4:0]`.
- **io_data_r_sv**: Always captures `reu_reg_mux` (cart/OPL have priority), no IOF_raw gating.
- **REU cpu_addr/cpu_we**: Use `dbg_cpu_addr`/`dbg_cpu_we` (direct CPU outputs, not buslogic-muxed).
- **IOF_raw**: Registered output, still used for REU cpu_cs (writes via original edge detection).
- **Software 1MHz**: `turbo_en <= '0'` when `scpu_speed_1mhz = '1'`.

### Key Insight
- `iof_detect` works **combinationally** in cpuDi mux (settles before CPU's FF samples)
- `IOF_raw` (same signal path) fails as **FF D-input** (doesn't meet setup time at clock edge)
- This is why ALL pipeline-based approaches failed and the direct combinational approach works

## Current State
- **REU register reads**: WORKING (5/5 boots from BASIC PEEK)
- **REU register writes**: WORKING (POKE/PEEK roundtrip verified)
- **REU DMA**: Still BROKEN (SDRAM write path issue from 2026-03-23)
- **Doom**: Untested with new fix — doom.reu loading via ioctl untested
- **MGL test program**: Unreliable (BRAM coherency issue, separate from IOF)

## Build Info
- Latest RBF: C64_MiSTer/output_files/C64.rbf (from commit 544f317)
- Build: ~72% ALMs, ~90% RAM blocks

## Doom Testing Results (2026-03-27)

### SuperRAM Verified Working (direct deploy)
- STA $000400 → LDA $000400 round-trip: PEEK(252) = 90 ($5A) ✓
- Only works after `mister_debug.py deploy` (not MGL)

### MGL Reload Breaks Native Mode
- Same RBF (checksums match: c38154b4b82abead173c90fc7423ba4c)
- After direct deploy: debug overlay shows, CLC/XCE works, SuperRAM reads work
- After MGL reload: NO debug overlay, CLC/XCE returns 0, SuperRAM broken
- Root cause unknown — possibly MGL reload sequence differs from direct core load
- Hardcoded settings (supercpu_enable, dbg_overlay_en = 1'b1) should apply but don't

### doom.reu Loading Fails
- `mbc load_rom C64 doom.reu` loads as PRG (ioctl_index = 0x01, not 0x81)
- MGL with `type="f" index="1"` should trigger load_reu but MGL reload breaks core
- doom.reu at offset 0x020000 has data (verified via dd on MiSTer filesystem)
- SuperRAM bank $02:$0010 returns $00 after both MGL and mbc (data not in SDRAM)
- After mbc load, one read returned 77 ($4D) — likely stale SDRAM data, not doom.reu

### Doom Loader Analysis
- doom_loader.prg uses REU DMA FETCH (cmd $91) — REU DMA still broken
- Even if doom.reu loaded correctly, the loader can't copy via DMA
- Alternative: rewrite loader to use LDA long from SuperRAM (if data loaded)

### MGL Reload Issue — EXPLAINED
- MGL reload breaks native mode because MiSTer applies different video scaler
  settings (different config name). The OSD doesn't capture in screenshots.
- **Workaround**: Deploy core normally, then load .reu via OSD (F12 key works,
  OSD not visible in MiSTer screenshots but visible on actual display)

### REU ioctl Loading — VERIFIED WORKING (2026-03-27)
- Diagnostic counter confirms: **262144 bytes loaded, ioctl_index = 0x81 (REU)**
- Data IS written to SDRAM at REU_ADDR (0x1000000+)
- **BUT**: LDA long from SuperRAM reads $00 for ioctl-written data
- STA/LDA long round-trip WORKS ($5A → $5A) — both use same address path
- **ROOT CAUSE**: `scpu_sdram_addr` combinational mux timing violation
  - ioctl writes to CORRECT SDRAM address (REU_ADDR + offset)
  - CPU LDA long reads from a DIFFERENT address (timing-dependent mux output)
  - STA/LDA round-trip works because BOTH STA and LDA use the same wrong address
  - This is the same -10ns timing slack issue that affected IOF_raw

### Diagnostic Registers Added (temporary)
- $DF09 = ioctl byte count low, $DF0A = mid, $DF0B = high
- $DF0C = ioctl_index captured at download start
- These should be removed before final commit

## Next Steps
1. **Fix scpu_sdram_addr timing**: The combinational mux has timing violations.
   Need to find a way to make it timing-clean without introducing the 1-cycle
   latency that CLAUDE.md warns about. Options:
   - Register the bank byte separately (supercpu_bank is already registered)
   - Use a multi-cycle constraint
   - Pre-compute the SuperRAM address and register it at cpu_cyc time
2. **After SDRAM fix**: Load doom.reu via OSD, verify data visible in SuperRAM
3. **Doom loader**: Rewrite to use LDA long instead of REU DMA (or fix DMA)
4. **REU DMA**: Still broken (separate SDRAM path issue)
