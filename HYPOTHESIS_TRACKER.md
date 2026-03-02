# Scrolling '@' Artifact — Hypothesis Tracker

**Artifact:** When SuperCPU (65C816) is enabled with standard or kickstart KERNAL ROM,
scrolling '@' characters appear on the READY screen. 6510 (T65) mode is clean.

**Confirmed mechanism:** VIC-II receives $00 (screen code '@') during real badline
c-access fetches from screen RAM ($0400+). Address routing is correct. The CPU is
NOT actively writing $00 to screen RAM during the artifact.

---

## Ruled Out (16 hypotheses eliminated)

| # | Hypothesis | Evidence | Source |
|---|-----------|----------|--------|
| H1 | CPU actively writes $00 to screen RAM | Sticky one-shot capture for CPU write of $00 to $0400-$07FF **never triggered** while artifact was visible | RootCause.md §"write-side ruled out" |
| H2 | XCE opcode at $FF62 causes mode switch | $FF62 = $FB = BNE branch offset, not XCE. MIF parser missed range entry `[3F60..3F61]:D0` | PLAN_NEXT.md §"Corrected Root-Cause" |
| H3 | Opcode $89 (BIT #imm) incompatibility | At $E969 (JiffyDOS), followed by BCS testing Carry. $89 doesn't affect Carry on either CPU → identical branch | OPCODE_89_ANALYSIS_REPORT.md |
| H4 | Bus contention (CPU vs VIC-II) | `ramWE` gated by `sysCycle >= CYCLE_CPU0`; VIC reads and CPU writes fully separated | PLAN_NEXT.md |
| H5 | WE signal polarity error | `we <= not localWe` in cpu_65c816.vhd correctly inverts P65C816 active-low to system active-high | PLAN_NEXT.md, ARCHITECTURE.md |
| H6 | STZ writes $00 to wrong address | STZ targets correct address (OUT_BUS="111"). Write-side capture never triggered anyway (H1) | PLAN_NEXT.md |
| H7 | Microcode pipeline glitch | MI registered, M combinational from MI — standard one-cycle pipeline, timing correct | PLAN_NEXT.md |
| H8 | Debug overlay corrupting RAM | Overlay only touches video output path, gated by OSD option; no RAM writes | PLAN_NEXT.md |
| H9 | 6510 mode also affected | T65 mode is clean. User confirmed artifact is 65C816-specific | PLAN_NEXT.md, RootCause.md |
| H10 | Wrong $0288 (CLRSCR target) | `PEEK(648)` returns 4 → screen base correctly at $0400 | PLAN_NEXT.md |
| H11 | NMOS undocumented opcodes in executed code | 43 "dangerous" bytes are in data tables (after JMP $E6AE at $EC75), not executed code | PLAN_NEXT.md |
| H12 | SuperRAM absent | Emulation mode uses bank $00 only; KERNAL/BASIC has no SuperRAM awareness | PLAN_NEXT.md |
| H13 | 20 MHz speed missing | 65C816 runs at 1 MHz currently (same enableCpu as T65); speed doesn't change init sequence | PLAN_NEXT.md |
| H14 | Address MUX sends wrong address to SDRAM | v6 capture: `C:0590 01 D:00 S:0590` — vicAddr == systemAddr confirmed. `supercpu_cycle` tightening had no effect | RootCause.md §"address gating" |
| H15 | CPUE-vs-VIC2 hold-mux selection bug | Runtime mode sweep ($D07B, modes 0-3): mismatch counter `C` remained $00 across all modes. Live and held samples coherent at compare point | RootCause.md §"runtime test-suite", session_handoff.md |
| H16 | scpu_rom_en active after kickstart completes | **Was** a real bug (K=$F8, B=$00 hitting $8092/$809B). **Fixed** by adding `and supercpu_rom_vis = '1'` to bank-$00 clause in fpga64_buslogic.vhd | SIMM_DETECT_ANALYSIS.md |

## Superseded (5 hypotheses — partially valid or overtaken by stronger evidence)

| # | Hypothesis | Why Superseded | Source |
|---|-----------|---------------|--------|
| H17 | JiffyDOS opcode $F2 causes '@' via IRQ handler | Correctly explains '@' under **JiffyDOS only** ($F2 at $FAAC, cursor blink 60Hz). But artifact also occurs with **standard ROM** which has no $F2 → not the primary cause | PLAN_NEXT.md §"Root Cause Found" |
| H18 | VIC-II $D018 misconfiguration | `PEEK(53272)` test was proposed but result never recorded. However v5/v6 captures confirmed VIC reads correct screen RAM addresses ($0400+), making $D018 misconfiguration unlikely | PLAN_NEXT.md §"Active Hypothesis" |
| H19 | Phantom keyboard '@' insertion (CIA1 race) | CIA1 Port B = $FF via PEEK($DC01) — no phantom key at rest. More critically, H1 proved CPU is NOT writing $00 to screen RAM at all, so keystroke stuffing is not the mechanism | ARCHITECTURE.md |
| H20 | CLRSCR not running / not finishing | PEEK(648)=4 confirmed. '@' rows scroll continuously (not a one-time init artifact). Read-side VIC capture confirmed ongoing $00 reads | PLAN_NEXT.md |
| H21 | INA ($1A) opcode difference near $F6AF | Mentioned but not pursued. Read-side evidence shifted investigation away from CPU execution differences | SUPERCPU_GUIDE.md |

## Still Open (4 active investigation threads)

### H23 — SDRAM `dout_r` clobbered by EXT/DMA phase read ⭐ PRIMARY
- **Status:** Most likely remaining cause
- **Theory:** C-access data from CPUC CE arrives in `dout_r` at ~CPUE.5. Must persist
  until next VIC2 when VIC latches it. Between CPUE.5 and next VIC2 there are:
  CPUF, EXT0-7, DMA0-3, VIC0, VIC1. If any EXT/DMA phase fires a new SDRAM CE
  after `q` returns to 0, the new read overwrites `dout_r`.
- **Supporting evidence:**
  - Artifact is workload-sensitive (amplified by screen writes, disappears when CPU busy)
  - Mismatch counter `C` = $00 at CPUE → clobber happens **after** CPUE, **before** VIC2
  - `F` (CPUF zero count) increases quickly → frequent $00 observations
  - `sdram.v`: new CE while q!=0 is ignored, but CE after q=0 starts fresh read
  - `io_cycle` and `ext_cycle` are active during EXT/DMA phases
- **What would confirm:** Capture showing `dout_r` value changes between CPUE.5 and VIC2
- **What would fix:** Dedicated VIC data hold register, or block SDRAM CE during the
  CPUE.5→VIC2 window

### H24 — RAM genuinely contains $00 (upstream content issue)
- **Status:** Cannot distinguish from H23 without provenance capture
- **Theory:** Some earlier 65C816 code path wrote $00 to screen RAM cells during
  initialization or operation, and VIC is reading correct (but wrong) content.
- **Against this theory:** Write-side sticky capture (H1) proved CPU is NOT actively
  writing $00. The artifact scrolls continuously, inconsistent with stale init data.
- **What would confirm:** Provenance capture showing no recent nonzero write before
  VIC-zero hit → RAM content genuinely $00
- **What would rule out:** Provenance capture showing recent nonzero write → data corrupted
  in transit (supports H23)

### H25 — Workload/timing sensitivity (observation, not root cause)
- **Status:** Established fact, needs explanation
- **Observations:**
  - SCPU OFF → clean
  - SCPU ON + Standard ROM → artifact
  - SCPU ON + SCPU kick ROM → artifact
  - SCPU ON + Diag ROM V22 → **clean**
  - SCPU ON + MVP debug ROM → artifact
  - Cursor movement → faster artifact
  - Tight screen-write loop → amplified artifact
  - Disk loading → artifact disappears
  - `F` varies run-to-run (timing-sensitive)
- **Implication:** Root cause is triggered by specific bus access patterns. Diag V22
  avoids conditions that trigger corruption. Consistent with H23 (different workloads
  create different EXT/DMA access densities).

### H27 — clk64/clk32 timing margin violation at VIC2 (NEW)
- **Status:** Low-medium probability, newly identified
- **Theory:** VIC0 g-access data arrives in `dout_r` at cycle 14.5 (clk32).
  VIC2 reads `dout_r` at cycle 14.0. Margin = 0.5 clk32 = 1 clk64 cycle.
  If `dout_r` (clk64 domain) and VIC's `vicDi` sampler (clk32 domain) have
  any phase offset or routing delay, VIC could read the new VIC0 data instead
  of the CPUC c-access data. This would explain workload sensitivity (routing
  delays vary with bus activity patterns).
- **Would fix:** Adding a registered hold of `dout_r` at CPUF (safely after
  CPUC data is ready but before VIC0 can clobber it) would eliminate the margin.

### H26 — VIC internal state corruption (colCounter, char ROM addressing)
- **Status:** Low probability, not fully ruled out
- **Theory:** The artifact could be something other than wrong screen codes.
- **Against:** v5/v6 captures confirmed VIC IS reading $00 at correct c-access
  addresses. VIC addressing logic appears correct.
- **Would need:** Provenance data first (H24) before investigating this further.

---

## Capture Iteration History

| Ver | What Was Checked | Result | Validity |
|-----|-----------------|--------|----------|
| v1 | CYCLE_VIC3, vicDi | No trigger | Wrong cycle — VIC3 has bitmap data |
| v2 | CYCLE_CPUE, no gate | Immediate trigger | False positive — non-badline |
| v3 | CYCLE_CPUE + cpuHasBus=0 | `R:0401 01 00 FF` | **Misleading** — CPUE has g-access (bitmap), not c-access; $00 may be normal |
| v4 | VIC0 addr + CPUE data | Never triggered | **Broken** — VIC0 has g-access addr, never matches $0400-$07FF |
| v5 | CPUC addr + VIC2 data | `I:0617 01 00 17` | **Valid** — correct pipeline; addr low byte matches |
| v6 | Label fix + full systemAddr | `C:0590 01 D:00 S:0590` | **Valid** — full address match; data-side fault confirmed |

---

## Critical Pipeline Model (Corrected)

Previous model was **WRONG** (VIC0→CPUE = c-access). Correct model:

| CE fires at | Address type | Data ready at | VIC latches at | Purpose |
|------------|-------------|--------------|----------------|---------|
| **VIC0** | g-access (~$1000+, bitmap) | CPUE.5 | **CPUE** (enaData) | Character bitmap row |
| **CPUC** | c-access ($0400+, screen code) | CPUE.5 | **next VIC2** (enaData) | Screen code for display |

The c-access data must survive in `dout_r` from CPUE.5 through CPUF→EXT→DMA→VIC0→VIC1
to reach VIC2. **This is the vulnerable window for H23.**

---

## Key Code Evidence (from this review)

### SDRAM CE mux in `c64.sv` (lines 997-998):
```systemverilog
.addr( io_cycle ? (cart_mem_req ? cart_addr   : io_cycle_addr ) : ext_cycle ? reu_ram_addr : scpu_sdram_addr ),
.ce  ( io_cycle ? (cart_mem_req ? cart_ce     : io_cycle_ce   ) : ext_cycle ? reu_ram_ce   : cart_ce     ),
```

### Who fires `ramCE` in `fpga64_sid_iec.vhd` (line 1289):
```vhdl
ramCE <= cs_ram when sysCycle = CYCLE_VIC0 or cpu_cyc = '1' else '0';
```
Only at **VIC0** and **CPU0-CPUF**. No CE during VIC1-VIC3 or EXT/DMA phases from the C64 bus.

### SDRAM controller timing (`sdram.v`, clk=clk64):
- CE rise → q=1 → ... → q=5 (STATE_READ): `dout_r <= sd_data` — **5 clk64 = 2.5 clk32 cycles**
- q=7 → q wraps to 0; new CE can start

### Vulnerability window analysis:
- CPUC CE fires at cycle 28 → `dout_r` has c-access data at cycle 30.5
- Next VIC0 CE fires at cycle 12 (next period) → `dout_r` overwritten at cycle 14.5
- VIC2 is cycle 14 → VIC reads `dout_r` at cycle 14.0
- **Margin: 0.5 clk32 = 1 clk64 cycle** between VIC2 read and VIC0 clobber

### During EXT/DMA phases (cycles 0-11 of next period):
- `io_cycle=1`: CE = `cart_mem_req ? cart_ce : io_cycle_ce`
  - No tape/load activity → `io_cycle_ce = 0`
  - No cartridge DMA → `cart_mem_req = 0` (needs verification)
  - **If both are 0: CE=0, no SDRAM access → dout_r safe**
- `ext_cycle=1`: CE = `reu_ram_ce = ~ext_cycle_d & ext_cycle & dma_req`
  - No REU DMA → `dma_req = 0` → CE=0 → safe

### Critical question for H23:
**Does `cart_mem_req` go high during `io_cycle` when SuperCPU is enabled?**
If the cartridge module (which handles SuperCPU ROM mapping) requests SDRAM during
EXT phases, that would fire `cart_ce` during `io_cycle` and clobber `dout_r`.
This needs to be traced through `cartridge.v`.

### Alternative timing concern (NEW — H27):
Even without EXT/DMA interference, the margin between VIC2 (cycle 14.0) and
VIC0 data arrival (cycle 14.5) is only **1 clk64 cycle**. If `dout_r` is in the
clk64 domain and `vicDi` is sampled on clk32, any phase misalignment or routing
delay could cause VIC to read the VIC0 g-access data instead of the CPUC c-access
data. This would explain the workload sensitivity — different bus access patterns
could shift the effective timing margin.

---

## Decision Matrix: What To Do Next

| Priority | Action | What It Tells Us | Effort | Risk |
|----------|--------|-----------------|--------|------|
| **1** | **Run test cartridge** (`scpu_vic_test.crt`) | Definitively distinguishes H23/H27 vs H24/H25 — no VHDL needed | Low (already built) | None |
| **2** | **Hold register experiment** (latch c-access data at CPUF) | Directly tests AND fixes H23/H27 | Medium (VHDL change) | Medium |
| 3 | Trace `cart_mem_req` during `io_cycle` | Confirms/denies EXT-phase SDRAM interference | Low (code analysis) | None |
| 4 | Analyze clk64/clk32 crossing at VIC2 | Confirms/denies 0.5-cycle margin violation (H27) | Low (code analysis) | None |
| 5 | Provenance capture (last write to VIC-hit addr) | Distinguishes H23/H27 from H24 if cartridge test is ambiguous | Medium (overlay + VHDL) | Low |

**Recommended path:**
1. Deploy `tools/test_cart/out/scpu_vic_test.crt` to MiSTer (no rebuild needed)
2. Run with SuperCPU ON — observe border color and screen content
3. If '@' + green border → implement hold register (priority 2)
4. If no '@' → bug is KERNAL-specific; shift focus to KERNAL path analysis

**Test cartridge:** `tools/test_cart/` — see README for usage.
Two variants available:
- `scpu_vic_test.crt` — basic Fill & Verify
- `scpu_vic_stress.crt` — CIA I/O hammering during verify (stress H23)

---

*Last updated: 2026-03-02*
*Total hypotheses: 27 (16 ruled out, 5 superseded, 5 open, 1 confirmed mechanism)*

---

## Test Cartridge

`tools/test_cart/scpu_vic_test.crt` — Ultimax-mode diagnostic cartridge.
Fills screen RAM with $01 ('A'), reads back via CPU (green=ok, red=fail).
If '@' appears with green border: H23/H27 confirmed. No VHDL rebuild needed.

Build: `python tools\test_cart\gen_scpu_test.py`
Deploy: `wsl scp tools/test_cart/out/scpu_vic_test.crt root@192.168.50.130:/media/fat/`
