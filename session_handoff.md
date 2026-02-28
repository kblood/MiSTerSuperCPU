# Session Handoff — SDRAM Returns $00 During Badline C-Access (Confirmed)

## Read These Files First
- `C:\LLM\C64\MiSTerSuperCPU\RootCause.md`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\fpga64_sid_iec.vhd`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\debug_overlay.sv`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\c64.sv`
- `C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\sdram.v` (SDRAM controller)

## Current State — v4 Capture Ready to Build & Test
- **SDRAM returning $00 during real badline c-access: CONFIRMED**
- v4 capture (pipeline-aligned) syntax-checks, needs full build + hardware test
- All changes in tree. User does builds.

## What We Know (Hardware Evidence)

### Root cause confirmed: SDRAM data path
- During real badline c-access (cpuHasBus=0, aec=1), `vicDi = $00` instead of $20
- The VIC aec mux is correct: aec=1 → vicDiAec = vicDi (SDRAM data used, not vicBus)
- vicBus = $FF (normal) — the bus latch is not involved
- **The SDRAM controller returns $00 for a screen RAM read that should return $20**

### SDRAM pipeline timing (critical understanding)
The SDRAM controller (sdram.v) takes 5 clk64 (= 2.5 clk32) from CE to data valid.
This creates a 1-slot pipeline:

| CE fires | Data ready | VIC latches | What VIC gets |
|---|---|---|---|
| VIC0 | VIC2.5 | **CPUE** (phi=1, c-access) | VIC0 read result |
| CPUC | CPUE.5 | **next VIC2** (phi=0, g-access) | CPUC read result |

The c-access (screen code fetch) latched at CPUE uses data from the **VIC0** SDRAM read.
The g-access (bitmap fetch) latched at VIC2 uses data from the **previous CPUC** SDRAM read.

### Capture iteration history
1. **v1 (CYCLE_VIC3)**: Checked vicDi at VIC3 — no trigger (was checking g-access bitmap data)
2. **v2 (CYCLE_CPUE, no gate)**: Triggered immediately — false positive (non-badline, vicBus=$00)
3. **v3 (CYCLE_CPUE + cpuHasBus=0)**: `R:0401 01 00 FF` — **CONFIRMED**: SDRAM returns $00 during real badline
4. **v4 (pipeline-aligned)**: Latches vicAddr+systemAddr at VIC0, checks at CPUE. Pending test.

## v4 Capture Design (Current Tree)
- Latches `vicAddr` AND `systemAddr[7:0]` at **CYCLE_VIC0** (pipeline-correct)
- Checks `vicDiAec` at **CYCLE_CPUE** with `cpuHasBus='0'` gate
- Row 3 format: `R:vvvv BA DD SS`
  - vvvv = vicAddr at VIC0
  - B = baLoc, A = aec (at CPUE)
  - DD = vicDi[5:0] at CPUE
  - SS = systemAddr[7:0] at VIC0
- **Key check**: if vvvv[7:0] = SS → correct address reached SDRAM, data is wrong
  if vvvv[7:0] ≠ SS → buslogic mux routed wrong address at VIC0

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

## Hypotheses for Wrong SDRAM Data
1. **Wrong address at VIC0**: buslogic routes cpuAddr instead of vicAddr at VIC0
   (v4 capture checks this via systemAddr comparison)
2. **VIC outputs non-screen address at VIC0**: VIC entity does refresh/sprite fetch
   instead of c-access, reading from a $00-containing location
3. **SDRAM CE collision**: Something triggers an extra SDRAM read between VIC0 and CPUE,
   restarting the state machine and clobbering VIC0's data
4. **Refresh collision**: Auto-refresh command issued while VIC0 read is in progress

## User Observations About the Artifact
- Scrolling `@` lines appear on READY screen with SCPU enabled + standard KERNAL ROM
- Turbo mode does NOT affect the lines (turbo is off by default)
- Lines disappear during JiffyDOS disk loading (CPU busy)
- Lines move at different speed/direction depending on which ROM code is executing
- Diagnostic ROM V22 does NOT show lines (all 10 tests pass)

## Files Modified (relative to C64_MiSTer/)
- `rtl/fpga64_sid_iec.vhd` — v4 VIC read capture (pipeline-aligned VIC0→CPUE)
- `rtl/debug_overlay.sv` — row 3 format: `R:vvvv BA DD SS`
- `c64.sv` — wiring (unchanged this session)

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
