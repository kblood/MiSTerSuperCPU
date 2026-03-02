# Session Handoff — VIC C-Access Pipeline Investigation

## Update — March 2, 2026 (Runtime VIC Mode Sweep + Workload Stress)

### Build/deploy sanity
- User rebuilt and deployed a fresh core image (`build_c64.ps1` + new RBF copy).
- New overlay row-4 format (`M/F/P/C`) confirmed active.

### ROM/mode matrix observations (latest)
- **SCPU OFF**:
  - No visual artifact.
  - Overlay rows 3/4 essentially idle/zero.
- **SCPU ON + Standard ROM**:
  - Reproducible artifact.
  - Example row 3: `C:0606 M:1 D:00 P:EA0E`
  - Row 4 counters active (`F`/`P` increase quickly), `C` observed at `00`.
- **SCPU ON + SCPU kick ROM**:
  - Artifact also reproducible.
  - Similar behavior: repeated VIC `$00` hits, row 4 `C` remains `00`.
- **SCPU ON + SCPU kick ROM + Diag ROM**:
  - No visual artifact observed.
  - Row 3 may still show write-side capture, but row 4 post-arm VIC-hit activity remains low/zero.

### Runtime hold-mode sweep result (`$D07B`, modes 0..3)
- Mode toggling works (`M` reflects selected mode).
- Visual artifact severity appears unchanged across modes.
- `C` (CPUE live-vs-held mismatch counter) stayed at `00`.
- Conclusion: CPUE/VIC2 hold-injection path did **not** change behavior in this workload.

### Workload sensitivity result
- Cursor movement increases artifact speed/irregularity.
- Tight screen-write BASIC loop substantially increases artifacts and character churn.
- `F`/`P` counters move rapidly; `C` remains `00`.
- `F` value after reset varies run-to-run (timing-sensitive rate variation), expected.

### Current narrowed conclusion
- Strongly supports **workload-sensitive read-side issue** rather than:
  - simple write-side `$00` provenance, or
  - a CPUE-vs-VIC2 hold-mux selection bug.
- With `C=00` across sweeps, data observed at compare point is coherent between live and held samples.

### Next recommended instrumentation (not yet implemented)
1. Sticky provenance capture at first VIC-zero event:
   - VIC read address/data
   - last CPU write to same address (data/PC/bank)
   - age since last write (small cycle counter)
2. Correlate whether VIC-zero occurs despite recent nonzero write to same cell.
3. If confirmed, focus next on upstream SDRAM/CE scheduling/read-return integrity under SCPU workloads.

## Update — March 1, 2026 (SignalTap Reset Attempt, Unstable)

### What changed in this attempt
- Build flow was moved back to **Quartus 17-first** behavior.
- `build_c64.ps1` now supports explicit Windows build mode:
  - `.\build_c64.ps1 -UseWindowsQuartus`
- Multiple clean full compiles were run in Quartus 17 and `.sof` was programmed via JTAG.

### SignalTap status at stop point
- JTAG chain is healthy (`DE-SoC [USB-1]`, device `5CSEBA6` visible).
- Compile/program succeeds, but SignalTap session became inconsistent due to profile churn:
  - `supercpu_debug.stp` and `supercpu_debug_1.stp` diverged.
  - At one point, `supercpu_debug.stp` had no `<instance ...>` section (empty Instance Manager).
  - At other points, profile carried `auto_signaltap_0` metadata that did not match active image.
  - GUI showed combinations of:
    - `Invalid JTAG configuration`
    - `Instance not found`
    - red node names (stale/unmapped signals).

### Key pitfall identified
- Mixing edited profiles and stale post-fit node mappings caused runtime mismatch:
  - STP instance/signal-set in GUI did not consistently match embedded debug fabric in programmed `.sof`.
  - Export attempts produced **Flow Summary CSV** (compile report), not SignalTap waveform/data logs.

### Current recommendation before any further SignalTap work
1. Pause SignalTap-based debugging for now (current state is fragile/noisy).
2. If resumed later, start from one canonical STP only (`supercpu_debug.stp`) and avoid `_1` variants.
3. Recreate instance and nodes from current build database, then do one clean compile/program cycle.
4. Validate export path by confirming CSV contains signal columns/sample rows (not Flow Summary header).

### Non-SignalTap Fallback Debug Plan (Recommended Short-Term)
1. Keep using on-screen overlay rows 3/4 as primary ground truth (`C:/M/D/P` + `A/P/C/B` fields).
2. Add one new lightweight overlay field for `last CPU write full address domain` (bank + 16-bit addr) and compare against VIC-hit address in same domain.
3. Add a temporary sticky counter for `low-bits match but full-match fail` to confirm/deny address-domain mismatch.
4. Add a compile-time option to latch VIC c-access data into a dedicated hold register and consume from that register at VIC2 (A/B experiment for data-lifetime corruption).
5. Instrument diagnostic ROM UI with minimal telemetry only:
   - latest `$0400` write addr/data/bank/PC
   - optional raw `$D0B2` display for SuperCPU detect-path sanity.
6. Run ROM mode matrix without SignalTap:
   - baseline C64 (no SCPU)
   - SCPU + standard ROM
   - SCPU + SCPU ROM
   and record overlay snapshots for each.
7. Use these pass/fail criteria:
   - If address-domain mismatch counters rise, fix matcher/address-domain plumbing first.
   - If address matches but VIC still consumes `$00`, prioritize data hold/lifetime mitigation path.
   - If behavior is ROM/workload-sensitive only, prioritize ROM-path timing stress reduction and write-provenance instrumentation.

## Update — March 1, 2026 (Latest)

### Confirmed behavior from hardware overlay
- With **SuperCPU ROM ON**:
  - `C:0400 M:1 D:00 P:81CB`
  - Interpretation: VIC consumed `$00` at `$0400`, and the last CPU screen write matched that address (`M:1`) from PC `$81CB`.
- With **SuperCPU ROM OFF**:
  - `C:0400 M:0 D:00 P:0000`
  - Interpretation: VIC still consumed `$00` at `$0400`, but no matching last CPU write was captured for that hit.

### New debug instrumentation added
- Overlay expanded to **4 rows**.
- New row 4 format:
  - `A:x P:xx C:xx B:xx`
  - `A` = write-capture arm state
  - `P` = VIC `$00` hit count before arm
  - `C` = VIC `$00` hit count after arm
  - `B` = bank of last captured screen write
- New exported debug signals:
  - `dbg_scr_wr_bank`, `dbg_scr_arm`
  - `dbg_vic_wr_match`, `dbg_vic_wr_pc`
  - `dbg_vic_prearm_cnt`, `dbg_vic_hit_cnt`

### SignalTap status
- USB-Blaster connectivity verified:
  - `DE-SoC [USB-1]` with `5CSEBA6` visible via `jtagconfig`.
- Active SignalTap profile file:
  - `C64_MiSTer/supercpu_debug.stp` (focused on VIC-hit + write provenance path)
- Project assignments now intended to use:
  - `USE_SIGNALTAP_FILE supercpu_debug.stp`
  - `SIGNALTAP_FILE supercpu_debug.stp`

### Build/toolchain notes
- Project build flow remains **Quartus 22.1 Lite** via `build_c64.ps1`.
- Quartus 17 is usable for **SignalTap/JTAG tools** (`quartus_stpw`, `quartus_pgm`, `jtagconfig`) but not reliable for compiling this qsf as-is.
- A previous transient Quartus internal fitter error was observed once; subsequent full compile on 22.1 succeeded.

### Helper scripts now present
- `launch_signaltap.ps1`
  - points to `C:\intelFPGA_lite\17.0\quartus\bin64`
  - opens `C64_MiSTer\supercpu_debug.stp`
- `program_sof_jtag.ps1`
  - programs `C64_MiSTer\output_files\C64.sof` to device `@2` on cable `DE-SoC [USB-1]`

### Immediate next debugging focus
1. Capture 2-3 SignalTap runs for ROM ON/OFF with same trigger (`dbg_vic_zero_hit_r==1`).
2. Verify whether ROM OFF path is truly non-CPU write or a missed early write (check `P` pre-arm counter growth).
3. Map PC `$81CB` path in kickstart flow to isolate why `$0400` receives `$00`.

## Latest Context Reset (Current Ground Truth)

- Two commits established the current ROM workflow split:
  - `0cf7109` — separate V22 loadable ROM workflow
  - `77c329e` — restored SuperCPU kickstart ROM for menu option
- SuperCPU kickstart in core (`C64_MiSTer/rtl/roms/scpu64.mif`) is restored to the
  real kickstart image (vectors `RST=$FC90 IRQ=$FC94 NMI=$FC8C`), not V22 diag.
- V22 now exists as a separate loadable C64 ROM path:
  - `tools/rom_builder/rom_inputs/debug_kernal_v22.bin` (8KB KERNAL slice)
  - `tools/rom_builder/out/debug_system_v22.rom` (loadable system ROM)
- Main debug ROM path remains independent:
  - `tools/rom_builder/rom_inputs/debug_kernal.bin` (from `gen_diag_kernal_mvp.py`)
  - `tools/rom_builder/out/debug_system.rom`
- Key observation update:
  - The new frame-synced MVP debug ROM no longer shows scrolling lines.
  - `C64_Original_MiSTer.ROM` still shows lines with SuperCPU.
  - This strongly indicates workload/timing sensitivity and supports a core-side
    data-lifetime issue, not a simple "wrong ROM image" issue.

## Current Practical ROM Commands

```powershell
# Main debug ROM (MVP/page-based)
python .\tools\diagrom\gen_diag_kernal_mvp.py
.\tools\rom_builder\build_and_deploy_debug.ps1 -CopyCore $false

# Separate V22 loadable ROM (does NOT replace debug_kernal.bin)
python .\gen_diag_rom.py
.\tools\rom_builder\build_roms.ps1 -Mode manifest -Manifest .\tools\rom_builder\profiles\debug_v22.json
```

## Read These Files First
- `C:\LLM\C64\MiSTerSuperCPU\RootCause.md`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\fpga64_sid_iec.vhd`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\debug_overlay.sv`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\c64.sv`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\sdram.v` (SDRAM controller)

## Current State — v6 Implemented, Artifact Still Reproducible
- v5 was validated on hardware: row-3 capture hit with `I:0617 01 00 17`.
- `I:` is only a label bug in `debug_overlay.sv`; this capture path is the v5
  c-access detector and should be read as `C:0617 01 00 17`.
- Decoded capture:
  - vicAddr@CPUC = $0617 (screen RAM range)
  - cpuHasBus@CPUC = 0 (real badline steal)
  - aec@VIC2 = 1 (VIC consuming RAM data path)
  - vicDi@VIC2 = $00 (VIC observed `@` code)
  - systemAddr[7:0]@CPUC = $17 (low byte matched vicAddr)

### Latest hardware capture after v6
- Row 3 now shows the corrected format and label:
  - `C:0590 01 D:00 S:0590`
- Interpretation:
  - Address path match confirmed (`vicAddr == systemAddr` at capture point).
  - Still seeing badline c-access `$00` consumed by VIC.
  - This narrows remaining fault to data-side behavior (true RAM content vs stale/clobbered return data), not address mux selection at capture time.

## v6 Work Completed (this session)
1. Fix row-3 VIC-hit label from `I:` to `C:`.
2. Change VIC-owned buslogic address selection to always drive `currentAddr <= vicAddr`
   when `cpuHasBus = 0` (remove `aec`-dependent `cpuAddr` fallback in VIC-owned cycles).
3. Expand VIC-hit diagnostics by latching/exporting full `systemAddr[15:0]`
   at CPUC and wiring it to overlay/debug path.

## New Diagnostic ROM Work (MVP)
- Added menu-driven diagnostic KERNAL MVP generator:
  - `tools/diagrom/gen_diag_kernal_mvp.py`
- Wrapped into existing ROM-builder deployment flow (`debug_system.rom`).
- Key observation:
  - MVP debug ROM still shows scrolling lines.
  - Earlier standalone V22 diagnostic ROM reportedly does not (or stopped after earlier revs).
  - This supports the hypothesis that workload/timing/profile details matter, not just "diagnostic vs standard ROM" as a binary distinction.
- MVP UI bug (status column overlap) was fixed.
- SuperCPU detect false-skip risk was reduced by forcing `$00/$01` memory map init before `$D0B2` probe.

## Critical Discovery: Previous Pipeline Model Was WRONG

### The CORRECT SDRAM pipeline timing
The VIC entity outputs different addresses depending on phi:
- `phi = '0'` (VIC phase): g-access address (character bitmap, CB & nextChar & rowCounter, ~$1000+)
- `phi = '1'` (CPU phase): c-access address (screen RAM, VM & colCounter, $0400+)

With `registeredAddress => true`, vicAddr = vicAddrReg (1-clock delay of vicAddrLoc).

| CE fires at | Address on bus | Type | Data ready | VIC latches at | Purpose |
|---|---|---|---|---|---|
| **VIC0** | g-access (~$1000+) | bitmap/char | VIC2.5 | **CPUE** (enaData) | Character bitmap row |
| **CPUC** | c-access ($0400+) | screen code | CPUE.5 | **next VIC2** (enaData) | Screen code for display |

**Previous (WRONG) model said VIC0→CPUE was c-access. It's actually g-access!**

### Why v3 capture was misleading
v3 triggered at CPUE with vicDiAec=$00 and cpuHasBus=0. We interpreted this as
"SDRAM returns $00 for screen code read". But CPUE has G-ACCESS data (bitmap),
not c-access data. $00 in bitmap data just means an empty pixel row — perfectly
normal. The v3 result may have been a false positive.

### Evidence trail
1. `video_vicII_656x.vhd` line 480: `if phi = '1' then vicAddrLoc <= VM & colCounter;`
   → c-access address only when phi='1' (CPU phase)
2. `video_vicII_656x.vhd` lines 448-452: when phi='0', default = g-access address
3. VIC entity line 279: `vicAddr <= vicAddrReg when registeredAddress` (1-clock delayed)
4. `registeredAddress => true` in instantiation (line 642)
5. `enableVic` fires at VIC2 and CPUE (line 491-494) — two data latches per C64 cycle
6. phi0_cpu = '0' during VIC0-VIC3, '1' during CPU0-CPUF

### What the v4 capture checked (BROKEN)
- Latched vicAddr at VIC0 → this was g-access address (~$1000+)
- Checked `vic_rd_addr_lat(15 downto 10) = "000001"` ($0400-$07FF)
- G-access address is NEVER in $0400-$07FF → condition NEVER true
- That's why the capture showed W: (write-side fallback) after 2+ minutes

## v5 Capture Design (Current Tree)
- Step 1: At **CPUC**, latch vicAddr (= c-access address VM & colCounter) and systemAddr[7:0]
  - Also latch cpuHasBus and set `vic_ca_pending = '1'`
- Step 2: At **VIC2** (next enaData pulse), check vicDi (= SDRAM data from CPUC read)
  - Gate: `vic_ca_pending='1'` AND `cpuHasBus_lat='0'` AND addr in $0400-$07FF AND vicDi=$00
  - If triggered: sticky capture, display `C:vvvv HA D:DD S:SSSS`
- Row 3 format: `C:vvvv HA D:DD S:SSSS`
  - vvvv = vicAddr at CPUC (c-access address)
  - H = cpuHasBus at CPUC (should be 0 during badline steal)
  - A = aec at VIC2 (should be 1)
  - DD = vicDi[5:0] at VIC2 (c-access data from SDRAM)
  - SS = systemAddr[7:0] at CPUC (verify SDRAM got correct address)
- **Key check**: if vvvv[7:0] = SS → correct address reached SDRAM
  if vvvv[7:0] ≠ SS → buslogic mux routed wrong address

## Key Architecture Details

### Bus cycle order (32 clk32 per 1MHz)
```
EXT0-3, DMA0-3, EXT4-7, VIC0-3, CPU0-F
```

### SDRAM access path
```
vicAddr → buslogic (currentAddr when cpuHasBus=0, aec=1) → systemAddr → ramAddr
  → cartridge (addr_out = addr_in for simple RAM) → cart_addr → scpu_sdram_addr
  → SDRAM controller .addr → physical SDRAM
  → sd_data → dout_r → dout → sdram_data → mem_in → data_out → c64_data_in
  → ramDin → buslogic ramData → dataToVic → vicDi → vicDiAec (when aec=1) → VIC di port
```

### SDRAM controller state machine (sdram.v)
```
CE rising edge → q=1: ACTIVATE, q=2: READ, q=5: capture dout_r, q=7: done (q=0)
Total: 7 clk64 cycles. Data at q=5 (2.5 clk32 from CE).
If new CE arrives while q≠0, the q+1 increment WINS over q<=1 — new CE is IGNORED.
```

### No interference from io_cycle/ext_cycle during VIC/CPU phases
- `io_cycle` active only during EXT0-EXT3 and EXT4-EXT7 (before VIC0)
- `ext_cycle` active only during DMA0-DMA3 (before VIC0)
- During VIC0-CPUF: SDRAM uses `scpu_sdram_addr` with `cart_ce`

### BUT: What about EXT-phase SDRAM reads between CPUE.5 and next VIC2?
The c-access data from CPUC arrives at CPUE.5 and must persist in dout_r until
the next cycle's VIC2. Between these points: CPUF, EXT0-7, DMA0-3, EXT4-7, VIC0, VIC1.
If any EXT/DMA phase triggers an SDRAM read, it could overwrite dout_r!
This is a potential issue to investigate if v5 capture doesn't trigger.

## Revised Hypotheses for @ Artifact
1. **CPUC read returns wrong data**: c-access SDRAM read at CPUC gets $00 instead
   of correct screen code — v5 capture directly tests this
2. **Data hold/clobber between read and consume**: SDRAM read during EXT/DMA/other phases between CPUE.5
   and next VIC2 overwrites the c-access data before VIC latches it
3. **Not a c-access issue at all**: the @ artifact has a different cause than
   VIC reading wrong screen codes (e.g., VIC internal state corruption, wrong
   colCounter, char ROM addressing issue)
4. **Original hypothesis may still hold**: maybe the pipeline model needs further
   verification — v5 results will clarify

## Immediate Next Steps
1. Add capture of "last CPU write to exact VIC-hit address" (addr/data/PC) to decide:
   - true `$00` content vs read-side corruption.
2. If write history does not explain `$00`, add explicit VIC data hold register experiment
   (decouple VIC consume point from shared SDRAM `dout_r` lifetime).
3. If needed, expose raw `$D0B2` value in diagnostic ROM UI to validate SuperCPU detection path.

## Backlog Note (Future)
- Consider making SuperCPU kick ROM externally loadable at runtime (similar to System ROM load path)
  so `scpu64.mif` does not need to be compiled into the core.
  - Pros: saves BRAM, easier SCPU ROM iteration without full core rebuild.
  - Cons: requires core-side loader + fallback logic.

## User Observations About the Artifact
- Scrolling `@` lines appear on READY screen with SCPU enabled + standard KERNAL ROM
- Turbo mode does NOT affect the lines (turbo is off by default)
- Lines disappear during JiffyDOS disk loading (CPU busy)
- Lines move at different speed/direction depending on which ROM code is executing
- Diagnostic ROM V22 does NOT show lines (all 10 tests pass)

## Capture Iteration History
1. **v1 (CYCLE_VIC3)**: Checked vicDi at VIC3 — no trigger
2. **v2 (CYCLE_CPUE, no gate)**: Triggered immediately — false positive (non-badline)
3. **v3 (CYCLE_CPUE + cpuHasBus=0)**: `R:0401 01 00 FF` — triggered, but was
   checking g-access data (bitmap), not c-access. The $00 may be normal bitmap data.
4. **v4 (VIC0 addr + CPUE data)**: BROKEN — VIC0 has g-access address, never matches
   $0400-$07FF screen RAM range. Capture never triggered.
5. **v5 (CPUC addr + VIC2 data)**: Pipeline-corrected. Latches c-access addr at CPUC,
   checks data at VIC2. Confirmed on hardware.
6. **v6 (label+mux+full systemAddr)**: Implemented and tested. Address match confirmed (`C:0590 ... S:0590`), issue persists.

## Files Modified (relative to C64_MiSTer/)
- `rtl/fpga64_sid_iec.vhd` — v5 VIC c-access capture (CPUC→VIC2 pipeline)
- `rtl/debug_overlay.sv` — row 3 format: `C:vvvv HA D:DD S:SSSS`
- `rtl/fpga64_buslogic.vhd` — VIC-owned address selection cleanup
- `c64.sv` — wiring for added `dbg_vic_zero_sysaddr`

## Tooling/Docs Added This Session
- `tools/rom_builder/` wrapper/deploy improvements (path handling, manifest robustness, MiSTer path with spaces)
- `tools/diagrom/` diagnostic KERNAL MVP generator
- Skill docs split:
  - `Skill_MiSTer.md` (general)
  - `Skill_MiSTer_C64.md` (C64-specific)

## Build Command
```powershell
Set-Location 'C:\LLM\C64\MiSTerSuperCPU'
.\build_c64.ps1 -SyntaxOnly   # syntax check (passes)
.\build_c64.ps1               # full build (~9.5 min)
```

## Deploy to MiSTer
```bash
scp C64_MiSTer/output_files/C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```
