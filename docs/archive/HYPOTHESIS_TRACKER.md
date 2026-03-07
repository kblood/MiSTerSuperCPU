# Scrolling '@' Artifact — Hypothesis Tracker

**Artifact:** When SuperCPU (65C816) is enabled with standard or kickstart KERNAL ROM,
scrolling '@' characters appear on the READY screen. 6510 (T65) mode is clean.

**Confirmed mechanism:** VIC-II receives $00 (screen code '@') during real badline
c-access fetches from screen RAM ($0400+). Address routing is correct. The CPU is
NOT actively writing $00 to screen RAM during the artifact.

---

## Ruled Out (19 hypotheses eliminated)

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
| H24 | RAM genuinely contains $00 (upstream content issue) | CharRAM test: CPU fills screen RAM with $01 and reads it back correctly (GREEN border) in all modes including SuperCPU ON. RAM retains correct values. Write-side sticky capture (H1) already proved CPU is NOT writing $00. | Cartridge test 2026-03-02 |
| H26 | VIC internal state corruption (colCounter, char ROM addressing) | CharRAM test with custom character set at $0800: VIC correctly displays filled blocks from RAM-based characters. VIC addressing and character lookup work correctly. v5/v6 captures already confirmed VIC reads correct addresses. | Cartridge test 2026-03-02 |
| H28 | Simple SDRAM CPU+VIC read contention | CharRAM test: CPU continuously reads screen RAM ($0400-$0700) while VIC simultaneously reads it for display. GREEN border + correct display in ALL modes. Simple read contention does NOT cause corruption. | Cartridge test 2026-03-02 |

## Superseded (5 hypotheses — partially valid or overtaken by stronger evidence)

| # | Hypothesis | Why Superseded | Source |
|---|-----------|---------------|--------|
| H17 | JiffyDOS opcode $F2 causes '@' via IRQ handler | Correctly explains '@' under **JiffyDOS only** ($F2 at $FAAC, cursor blink 60Hz). But artifact also occurs with **standard ROM** which has no $F2 → not the primary cause | PLAN_NEXT.md §"Root Cause Found" |
| H18 | VIC-II $D018 misconfiguration | `PEEK(53272)` test was proposed but result never recorded. However v5/v6 captures confirmed VIC reads correct screen RAM addresses ($0400+), making $D018 misconfiguration unlikely | PLAN_NEXT.md §"Active Hypothesis" |
| H19 | Phantom keyboard '@' insertion (CIA1 race) | CIA1 Port B = $FF via PEEK($DC01) — no phantom key at rest. More critically, H1 proved CPU is NOT writing $00 to screen RAM at all, so keystroke stuffing is not the mechanism | ARCHITECTURE.md |
| H20 | CLRSCR not running / not finishing | PEEK(648)=4 confirmed. '@' rows scroll continuously (not a one-time init artifact). Read-side VIC capture confirmed ongoing $00 reads | PLAN_NEXT.md |
| H21 | INA ($1A) opcode difference near $F6AF | Mentioned but not pursued. Read-side evidence shifted investigation away from CPU execution differences | SUPERCPU_GUIDE.md |

## ROOT CAUSE IDENTIFIED AND FIXED ✅

### H31 — P65C816 frozen WE during badline halt grants cpuHasBus incorrectly ⭐ ROOT CAUSE — FIXED
- **Status:** **ROOT CAUSE CONFIRMED AND FIXED** (2026-03-07)
- **Theory:** When BA goes low (badline), the T65 completes writes via `really_rdy = Rdy OR
  NOT WRn_i`, then halts on the next read cycle with `cpuWe='0'`. The P65C816 halts
  IMMEDIATELY (even mid-write) because `EN = RDY_IN AND CE` — its WE output freezes at
  `'1'` (write active). At VIC3, the `cpuHasBus` logic checks `cpuWe='1'` and grants the
  bus to the CPU during badlines: `systemAddr = cpuAddr` instead of `vicAddr`. The VIC's
  c-access reads the CPU's frozen write address instead of screen RAM → display corruption.
- **Diagnostic evidence:**
  - T65-as-SuperCPU test: P65C816 instantiated (FPGA routing pressure) but T65 drives bus
    → artifact DISAPPEARS. Confirms P65C816 behavioral outputs are the cause.
  - cpuWe fix (`cpuWe_816 AND baLoc`): gates frozen WE during BA low
    → artifact GONE. Games tested and working.
- **Why indirect addressing triggers:** Indirect modes (`LDA ($zp),Y`) take 7 cycles on
  P65C816 (vs 5-6 on T65) with 2 phantom cycles. The longer instruction time increases the
  probability that KERNAL IRQ handler writes (stack push, STA) coincide with a badline.
  Absolute modes take fewer cycles → lower collision probability.
- **Fix:** One line in `fpga64_sid_iec.vhd` CPU MUX:
  ```vhdl
  cpuWe_pre <= (cpuWe_816 and baLoc) when supercpu_en = '1' else cpuWe_6510;
  ```
  When BA is low, force system-visible WE to '0' (read). The P65C816 is already halted
  so no actual write is lost — it completes when BA goes high and the CPU resumes.

### H29 — P65C816 phantom bus cycles (VDA=0, VPA=0) — CONTRIBUTING FACTOR, FIX REVERTED
- **Status:** Contributing factor, but NOT the root cause. VDA/VPA gating was architecturally
  correct (the real SuperCPU does this) but the implementation had bugs:
  1. Suppressing `cpu_cyc` during phantom cycles also suppressed `enableCpu` (derived from
     `cpu_cyc`), deadlocking the CPU in phantom states.
  2. During badlines, frozen VDA=0/VPA=0 suppressed the VIC's c-access CE at CPUC.
  Future re-implementation should gate `ramCE` separately from `cpu_cyc`.

### H30 — VIC c-access latch timing model — RESOLVED
- **Status:** Resolved — the 0.5 clk32 timing margin is not the primary issue. The display
  artifact was caused by H31 (cpuHasBus granting bus to CPU during badlines), not by SDRAM
  timing. Hold register disabled (was injecting wrong ZP data). Early CE disabled.
  Full analysis in `docs/sdram_vic_datapath.md`.

---

## Resolved — explained by H31 (4 hypotheses)

### H25 — Workload/timing sensitivity — EXPLAINED BY H31
- **Status:** Resolved — indirect addressing modes have longer cycle counts, increasing
  the probability that a write cycle (from KERNAL IRQ handler or test code) coincides
  with a badline. The P65C816's frozen WE then corrupts cpuHasBus.

### H23 — SDRAM `dout_r` clobbered — EXPLAINED BY H31
- **Status:** Resolved — `dout_r` was not clobbered by phantom reads. Instead, the SDRAM
  was reading the wrong address entirely (cpuAddr instead of vicAddr) due to cpuHasBus='1'.

### H27 — clk64/clk32 timing margin — SUPERSEDED BY H31
- **Status:** Resolved — the 0.5-cycle timing margin is adequate. The artifact was caused
  by the address mux selecting the wrong source, not by SDRAM timing.

### H29 — phantom bus cycles — SUPERSEDED BY H31
- **Status:** Contributing factor (phantom cycles increase instruction time) but not the
  direct cause. VDA/VPA gating fix had implementation bugs (see H29 above).

### KERNAL-mimic test evidence (complete)

| Mode | What | Artifact? | Implication |
|------|------|-----------|-------------|
| M0 | Baseline (fill + read-only verify) | No | Absolute reads safe |
| M1 | + CIA1 Timer A IRQ 60Hz | No | IRQs safe |
| M2 | + Cursor blink (1 byte write in IRQ) | No | Single writes safe |
| **M3** | **+ Scroll (LDA/STA (zp),Y in IRQ)** | **YES** | Indirect addressing triggers |
| M4 | + Keyboard scan | Same as M3 | — |
| M5 | All combined | Same as M3 | — |
| M6 | Write-only refill, no IRQ | No | Writes alone safe |
| **M7** | **Scroll copy, no IRQ** | **YES** | Not IRQ-specific |
| **M8** | **Indirect read-only (no writes)** | **YES** | Reads alone trigger |
| M9 | Absolute read+write (LDA/STA absx) | No | No internal cycles = safe |
| M10 | Dense absolute reads (8x back-to-back) | No | Not bus density |
| M11 | Alternating ZP+screen absolute reads | No | Not address pattern |
| **M12** | **Indirect reads from char RAM ($0800)** | **YES** | Target address irrelevant |

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

## Critical Pipeline Model (RE-CORRECTED 2026-03-03)

**Previous "corrected" model was ALSO WRONG.** Verified against actual VHDL code:

### SDRAM Timing
- SDRAM controller runs at **clk64** (sdram.v)
- STATE_CMD_START=0, STATE_CMD_CONT=2, STATE_READ=**5**, STATE_LAST=7
- From CE at clk32 edge to data: detected at +0.5 clk32 (first clk64), q=5 at +2.5 clk32 total
- `dout_r` is registered (clk64), `dout` is combinational from dout_r

### Verified Pipeline (from VHDL code analysis)

| CE fires at | Address type | dout_r updated at | VIC latches at | Purpose |
|------------|-------------|-------------------|----------------|---------|
| **VIC0** (cycle 12) | g-access (~$1000+, bitmap) | **VIC2.5** (cycle 14.5) | **VIC3** (cycle 15, phi='0') | Character bitmap row |
| **CPUC** (cycle 28) | c-access ($0400+, screen code) | **CPUE.5** (cycle 30.5) | **CPUF** (cycle 31, phi='1') | Screen code into charStore |

### VIC Latch Evidence (video_vicII_656x.vhd lines 497-512)
```vhdl
if enaData = '1' and shiftChars and phi = '1' then  -- fires at CPUF
    nextChar(7 downto 0) <= di;  -- c-access screen code
```
- `enaData` = enableVic: fires at VIC2 and CPUE (registered)
- Due to registration, VIC sees enaData='1' at **VIC3** and **CPUF**
- VIC3: phi='0' → condition FALSE (c-access requires phi='1')
- **CPUF: phi='1' → condition TRUE → VIC latches c-access data here**

### Margin
Both g-access and c-access have **0.5 clk32 (~15.6ns)** between dout_r update and VIC latch.
This is tight but should be sufficient for combinational propagation.

### H29 VDA/VPA Fix Status
- **Implemented** in commit f14a259
- **REVERTED** in commit b917948 — "made things worse"
- H29 is NOT actually confirmed fixed. The VDA/VPA gating approach needs re-evaluation.
- See `docs/sdram_vic_datapath.md` for full data path analysis

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

## Status: ROOT CAUSE FIXED AND VERIFIED ✅

**Root cause:** H31 — P65C816 frozen WE during badline halt.
**Fix:** `cpuWe_pre <= (cpuWe_816 and baLoc)` in `fpga64_sid_iec.vhd`

**Verification (2026-03-07):**
1. ✅ T65-as-SuperCPU diagnostic test — artifact disappears (P65C816 behavioural confirmed)
2. ✅ cpuWe badline fix applied — artifact gone on READY screen
3. ✅ Games tested with SuperCPU ON — working correctly
4. **TODO:** Test cartridge verification (M3/M7/M8/M12 should now be clean)
5. **TODO:** Lorenz test suite (6510 mode regression check)
6. **TODO:** Re-evaluate VDA/VPA gating with corrected implementation (separate from cpu_cyc)

---

*Last updated: 2026-03-07*
*Total hypotheses: 31 (19 ruled out, 5 superseded, 5 resolved by H31, 1 contributing factor, 1 root cause fixed)*
*ROOT CAUSE: H31 — P65C816 frozen WE during badline halt grants cpuHasBus incorrectly*

---

## Test Cartridge Results (2026-03-02)

### Cartridge tests completed on MiSTer hardware:

| Test | Mode | Border | Visual | CPU verify | Conclusion |
|------|------|--------|--------|------------|------------|
| scpu_vic_test.crt | All | GREEN | No chars visible | Pass | Char ROM at $1000 inaccessible in Ultimax mode |
| scpu_vic_stress.crt | SCPU OFF | GREEN | No chars visible | Pass | Same char ROM issue |
| scpu_vic_stress.crt | SCPU ON | GREEN | 2 scrolling white lines | Pass | Stress I/O creates minor visual artifact |
| scpu_bitmap_test.crt (no verify) | All | GREEN | Clean pattern | N/A | Bitmap displays correctly when CPU idle |
| scpu_bitmap_test.crt (with verify) | SCPU OFF | RED | Clean pattern | Fail | CPU reads open bus at $2000+ (Ultimax limitation) |
| scpu_bitmap_test.crt (with verify) | SCPU ON | RED | Flickering lines | Fail | Open bus reads + SuperCPU side effects |
| **scpu_charram_test.crt** | **All** | **GREEN** | **All white (correct)** | **Pass** | **No corruption in any mode** |

### KERNAL-mimic test results (2026-03-02):

| Test | SCPU ON | Visual | Conclusion |
|------|---------|--------|------------|
| M0: Baseline (fill + verify) | GREEN, clean | Solid white | Read-only verify is safe |
| M1: + CIA1 IRQ 60Hz | GREEN, clean | Solid white | IRQs alone are safe |
| M2: + Cursor blink | GREEN, clean | Solid white | Single-byte IRQ writes safe |
| **M3: + Scroll copy (IRQ)** | **GREEN, artifact** | **Blue lines flickering** | **Block copy triggers corruption** |
| M4: + Keyboard scan | GREEN, artifact | Same as M3 | Keyboard scan adds nothing |
| M5: All combined | GREEN, artifact | Same as M3 | Scroll is the dominant trigger |
| M6: Write-only refill (no IRQ) | GREEN, clean | Solid white | **Write-only is safe** |
| **M7: Scroll copy (no IRQ)** | **GREEN, artifact** | **Blue lines flickering** | **NOT IRQ-specific** |
| **M8: Indirect read-only** | **GREEN, artifact** | **Blue lines flickering** | **Reads alone trigger it** |
| M9: Absolute read+write | GREEN, clean | Solid white | **Absolute addressing is safe** |

### Key discoveries:
1. **Ultimax mode limits CPU to $0000-$0FFF RAM** — bitmap at $2000 and char ROM at $1000 are inaccessible
2. **Character ROM is NOT available to VIC in Ultimax mode** on MiSTer — must use RAM-based characters at $0800
3. **Simple CPU+VIC SDRAM contention does NOT cause corruption** — even with SuperCPU ON
4. **Indirect-indexed reads `LDA (zp),Y` are the trigger** — generates 3 SDRAM reads per instruction
5. **NOT IRQ-specific** — M7 (main loop) triggers same as M3 (IRQ handler)
6. **NOT write-related** — M8 (read-only) triggers; M6 (write-only) and M9 (read+write via absx) are clean
7. **Bus density is the likely variable** — indirect addressing generates ~1 SDRAM read per 4 cycles vs ~1 per 8-10 for absolute

### Build & deploy:
```powershell
.\tools\test_cart\build_and_deploy_carts.ps1 -RemotePath "/media/usb0/Games/C64/C64 Kernals/CRT/"
```
