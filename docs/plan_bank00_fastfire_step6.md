# Step 6 — bank-$00 BRAM fast-fire (the speed payoff)

Builds on the HW-validated step-2 foundation (commit `36a8d12`, build `476e1a5d`):
the bottom-64KB (bank $00, incl $01 mirror) is now served by an authoritative
on-chip BRAM (`bank00_mem` in c64.sv), proven byte-equivalent at the existing
4-apart cadence (boot 38911 bytes, Doom engine bank $2C identical to control,
Lorenz scpu+t65 all-ok). Step 6 turns that into speed.

## Goal
Fast-fire the CPU at **k=2 (2-apart)** on bank-$00 accesses (served by BRAM,
~1 clk64 latency) while SuperRAM stays 4-apart (SDRAM, ~5-6 clk64). Doom
bank-$00 fraction = 38.8% (BANKFRAC, `bffd2e4`) ⇒ eff ~1.24-1.33×.

## Why this is NOT the 6-dead-lever setup-time death class
The 6 dead levers (cache×5, raised-clock, alt-fire, internal-fast-fire,
demand-arbiter) all wedged because firing `cpu_cyc` faster advanced the CPU
PHASE ahead of the ~4-clk64 SDRAM latency, so the FOLLOWING memory fetch raced
SDRAM (`project_bug2_setup_time_class`). Here the fast-fired access is a bank-$00
BRAM read = **matched latency** (1 clk64 << the 4-clk64 +2 consume window), and
crucially **bank-$00 cycles do NOT pulse SDRAM ce** so the SDRAM is idle going
into the next access. The bank-$00→SuperRAM transition therefore starts from an
idle SDRAM and keeps the full proven "011" 4-apart reservation — no SDRAM race.

## The arbiter consume mechanism (fpga64_sid_iec.vhd, verified)
- `cpu_cyc` (SDRAM prefetch/reserve) fires at CPU0/4/8/C, gated `sdram_busy='0'`
  (:3783). On a `cpu_cyc & cs_ram` it loads `sdram_busy_cnt="011"` (:3846-3851),
  which clears after 3 clk32 ⇒ next CPU slot at +4 = 4-apart floor.
- `cpu_cyc_s <= cpu_cyc_s(0) & cpu_cyc` (:3926). `enableCpu` (CPU advance/consume)
  follows `cpu_cyc_s(1)` = +2 clk32 after the fire (CPU0→CPU2) (:3977).
- `data_ready` (:3700) gates `enableCpu` via the RDY handshake: for `cs_ram` reads
  it waits for `sdram_data_valid_sync`.
- `ramCE <= cs_ram when sysCycle=CYCLE_VIC0 or cpu_cyc='1'` (:3635) → c64.sv
  `ram_ce`→`cart_ce`→`sdram_eff_ce` (BRAM + SDRAM both keyed off this today).

## The change (gated `BANK00_FASTFIRE`, default false ⇒ RBF-identical)

### c64.sv
1. New combinational output `is_bank00` (already computed) → drive a NEW fpga64
   input port `bank00_acc` so fpga64's classifier matches c64.sv EXACTLY (incl
   the $01→$00 mirror). MUST match or a mirror read gets SDRAM-ce-suppressed here
   but `data_ready` never satisfied there ⇒ permanent stall.
2. Separate the BRAM ce from the SDRAM ce:
   - BRAM `always` block keeps using `sdram_eff_ce` (captures all writes/reads).
   - `sdram_pm.ce` = `sdram_eff_ce & ~(BANK00_FASTFIRE & is_bank00)` ⇒ bank-$00
     cycles do NOT pulse SDRAM ce (SDRAM stays idle). SuperRAM/cart/io unchanged.
   - Writes: bank-$00 writes still captured by BRAM (gated on `sdram_eff_ce &
     sdram_eff_we & is_bank00`, independent of SDRAM ce). SDRAM bank $00 becomes
     stale/unused (fine — BRAM authoritative). NOTE: io_cycle PRG-inject writes to
     bank $00 still reach BRAM via `sdram_eff_ce` (io_cycle asserts it).

### fpga64_sid_iec.vhd
3. New input port `bank00_acc : in std_logic`. Classifier:
   `b00_fast <= '1' when BANK00_FASTFIRE and supercpu_en='1' and cs_ram='1'
                and bank00_acc='1' and scpu_force_1mhz='0' and dma_active='0'`.
4. `cpu_cyc` gen: add an even-slot term so a bank-$00 access can fire 2-apart:
   `or (b00_fast='1' and (sysCycle=CPU2 or CPU6 or CPUA or CPUE))`
   — still inside the `sdram_busy='0'` gate (so a pending SuperRAM "011" still
   blocks it; only a prior bank-$00 "001" frees CPU2 in time).
5. `sdram_busy_cnt` load: for a bank-$00 `cpu_cyc`, load `"001"` (clears in
   1 clk32 ⇒ next even slot free at +2) instead of `"011"`:
   `if cpu_cyc='1' and cs_ram='1' then
        if b00_fast='1' then sdram_busy_cnt<="001"; else "011"/hit-pred end if`
   The predictor-row update should be SKIPPED for bank-$00 (no SDRAM row opened).
6. `data_ready`: add a bank-$00 term (SDRAM ce suppressed ⇒ no `sdram_data_valid`;
   `bram_q` is ready ~1 clk64 after the fire, well before the +2/+4-clk64 consume):
   `else (rp_cache_hit or sdram_data_valid_sync or b00_fast)`.
   (b00_fast is combinational on the access; bram_q is valid by the consume edge.)

## Transition correctness (the crux)
- bank-$00 @ CPU0: cpu_cyc, busy<="001", **SDRAM ce suppressed**. CPU1: busy→0.
  cpu_cyc_s(1)@CPU2 → consume #0 (data=bram_q, data_ready via b00_fast).
- bank-$00 @ CPU2 (b00_fast even-slot term): cpu_cyc, busy<="001", ce suppressed.
  ⇒ steady 2-apart.
- SuperRAM follows @ CPU4 (CPU4 is a baseline slot; busy cleared @ CPU3): cpu_cyc,
  busy<="011", **SDRAM ce PULSES**. SDRAM was idle (prior bank-$00 suppressed) ⇒
  clean read. "011" forces next slot to CPU8 = 4-apart. consume waits
  sdram_data_valid_sync (RDY handshake) as today. ✓
- SuperRAM→bank-$00: SuperRAM @ CPU0 busy="011" blocks CPU2/CPU4; next fire CPU4.
  If CPU4 is bank-$00, fires (busy clear), 2-apart resumes. The SuperRAM read's
  SDRAM transaction completed during its 4-apart window (unchanged). ✓

## CORRECTION after Codex red-team (tools/codex-out/bank00-fastfire-step6-review.txt)
**v1 (above) is FLAWED — do NOT build it.** The arbiter assumes `cpu_cyc` (issue)
and `enableCpu` (consume) are at DISJOINT slots; the CPU does not advance its
address until the consume edge (:3977, cache comment :5666-5670). Firing a new
`cpu_cyc` at CPU2 (the consume slot of the CPU0 access) would issue using the OLD
address = duplicate access; and `bram_q`'s "held until next ce" breaks when the
next ce is the consume slot. Codex CONFIRMED the SDRAM-transition safety is sound
(bank-$00 suppresses ce ⇒ CPU4 SuperRAM starts idle, full "011"); the flaw is the
fast-path BRAM data delivery, not the SDRAM race.

### v2 design (alt-fire-pattern, to be Codex-vetted before building)
Model bank-$00 like the existing alt-fire FAST path (:3980-3989): fast-fire
**`enableCpu` (consume) 2-apart**, NOT a new `cpu_cyc` prefetch. The authoritative
BRAM is the key difference from the dead alt-fire cache (no fill / no `_d1` /
no coherency = the actual alt-fire corruptor per `project_bug2_setup_time_class`).
1. **c64.sv BRAM → simple-dual-port, CONTINUOUS read.** Read port reads
   `bank00_mem[sdram_eff_addr[15:0]]` EVERY clk64 (decoupled from `cpu_cyc`/ce);
   `bram_q` follows the bus address with 1-clk64 latency. Write port gated on
   `sdram_eff_ce & sdram_eff_we & is_bank00`. (M10K SDP, still ~52 blocks.)
   This removes the "held until next ce" hazard — bram_q just tracks the address.
2. **fpga64 cpu_cyc: EXCLUDE bank-$00** (when FASTFIRE) — bank-$00 needs no SDRAM
   prefetch. So `cpu_cyc` fires only for SuperRAM/io (4-apart, unchanged). ⇒ no
   SDRAM ce for bank-$00 automatically (ramCE gated on cpu_cyc), no busy_cnt load.
3. **fpga64 enableCpu: add a bank-$00 FAST branch** to the scheduler (mirror
   :3980-3989): `enableCpu<='1'` when `b00_fast='1' and en_gap>=2 and baLoc and
   cpu816_rdy_to_cpu and sysCycle in {CPU2,CPU4,CPU6,CPU8,CPUA,CPUC}` (NOT CPUE —
   Codex #5: CPUE+2 wraps into EXT). The MAIN path keeps `en_gap>=3` (:3980) so a
   SuperRAM access after a bank-$00 fast fire still gets its full 4-apart SDRAM
   window. data_ready b00_fast term (no sdram_data_valid for bank-$00).
4. **Address phasing (the remaining risk to vet):** at the 2-apart consume edge,
   `bram_q` must equal BRAM[the consuming access's addr]. The CPU advanced on the
   PRIOR enableCpu, so the address has been stable ~2 clk32 (4 clk64) ⇒ bram_q
   (1-clk64 latency) has settled. Must confirm `sdram_eff_addr` reflects the
   consuming (not the next) access at the consume edge, and the `-setup 2` cpuAddr
   multicycle (C64.sdc:44) doesn't make the address late vs the BRAM read.

## Validation
- STA: TNS must stay 0. k=2 consume window = 2 clk32 (62.5ns) ≫ CPU path ~27ns and
  ≫ BRAM 1-clk64 read ⇒ expected clean. (k=1 would need explicit STA; not now.)
- GHDL gap: the c64.sv-BRAM ↔ fpga64-arbiter handshake spans Verilog+VHDL ⇒ not
  GHDL-testable as a unit. But a cadence/handshake LOGIC bug is HW-DETERMINISTIC
  (boot wedge / Doom corrupt), NOT the zero-delay-blind setup-time class. Gated ⇒
  safe to trial; revert = RBF-identical.
- HW gate (all must pass, A/B vs `3698680a`): boot READY + SCPU64 V0.07 + idle PC
  $E5CD-$E5D6 (not pinned); Lorenz scpu + t65 all-ok; Doom engine bank $2C (not
  crashed); eff-MHz delta POSITIVE (the actual win). Measure eff-MHz via the
  existing UART or a cycle counter.

## Risks / stop conditions
- Classifier mismatch (fpga64 `bank00_acc` vs c64.sv `is_bank00`) = stall wedge ⇒
  drive from ONE source (c64.sv→port).
- If SDRAM ce suppression races a VIC bank-$00 fetch (VIC reads bank $00 too): VIC
  reads via the same override get `bram_q`; VIC does NOT use the `cpu_cyc` fast
  path (VIC has its own CYCLE_VIC0 ce). Suppressing SDRAM ce for VIC bank-$00
  reads is fine (VIC gets bram_q via override) — but CONFIRM VIC `data` path
  doesn't depend on `sdram_data_valid` (it doesn't; VIC latches at its fixed slot).
- A wedge here is the 7th; if it wedges, record as death and the lever's CEILING
  becomes "step-2 BRAM equivalence only, no speedup" (still a clean refactor).

## v3 design (to be Codex-vetted, supersedes v1+v2)
v2 was unbuildable: excluding bank-$00 entirely from `cpu_cyc` killed the BRAM
write strobe (`sdram_eff_ce` ← `cart_ce` ← `ramCE` ← `cpu_cyc`). v3 SPLITS reads
from writes: fast-fire only bank-$00 **READS** (enableCpu-only), keep bank-$00
**WRITES** + all SuperRAM/io on the existing `cpu_cyc` MAIN path (4-apart). This
preserves both the write strobe AND — crucially — the fixed `cpu_cyc`(issue)→
`cpu_cyc_s(1)`(consume) 2-clk32 SDRAM window for every SuperRAM/write access.

### Why v3 should NOT repeat the internal-fast-fire wedge
internal-fast-fire's death (`project_internal_cycle_fast_fire`) = advancing the
CPU phase 2-apart so the FOLLOWING memory fetch raced SDRAM latency. v3's fast
branch copies the **ALT_FIRE MAIN guard `en_gap>=3`** (NOT internal-fast-fire's
unguarded `if cpu_cyc_s(1)`). Trace of bank-$00 read (fast @CPU2) → SuperRAM:
- bank-$00 read fast-fire @CPU2 (en_gap←0). NO cpu_cyc (read excluded), NO SDRAM
  ce (suppressed in c64.sv), NO busy load. CPU advances → presents SuperRAM addr.
- SuperRAM `cpu_cyc` fires @CPU4 (baseline slot, busy clear, b00_fast_read=0),
  busy="011". `cpu_cyc_s(1)` @CPU6. en_gap CPU2→CPU6 = 4 ≥3 → MAIN fires @CPU6.
- **SuperRAM issue→consume = CPU4→CPU6 = 2 clk32 = the SAME fixed window as
  baseline** (cpu_cyc→cpu_cyc_s(1)). The fast bank-$00 advance moves SuperRAM
  earlier in wall-clock but does NOT compress its SDRAM window. ✓ This is the
  difference from internal-fast-fire (which had no such window-preserving guard).

### c64.sv changes (gated `BANK00_FASTFIRE`, default 0 ⇒ RBF-identical)
1. **Continuous-read BRAM** (decouple `bram_q` from ce): read EVERY clk64 from
   `sdram_eff_addr[15:0]`; register `is_bank00` alongside as `is_bank00_q`. Write
   port unchanged (gated `sdram_eff_ce & sdram_eff_we & is_bank00`). Override:
   `sdram_data_eff = (BANK00_BRAM & is_bank00_q) ? bram_q : sdram_data`. (Removes
   the "held until next ce" hazard Codex flagged in v1/v2; `bram_q` just tracks
   the bus addr with 1-clk64 latency.) NOTE: this also subsumes step-2 `b00_sel`.
2. **Suppress SDRAM ce for bank-$00 READS**:
   `wire bank00_rd_supp = BANK00_FASTFIRE & is_bank00 & ~sdram_eff_we;`
   `.ce( sdram_eff_ce & ~bank00_rd_supp )`. Writes keep ce (BRAM write strobe +
   harmless stale SDRAM write). Invariant: ce suppressed ⟺ override serves bram_q
   (both keyed on is_bank00) ⇒ always correct since BRAM is authoritative.

### fpga64_sid_iec.vhd changes (gated `BANK00_FASTFIRE`)
3. **Internal classifier** (no new port — avoids the v1 port-mismatch wedge;
   classify ONLY addr_hi=$00 so the bank-$01 mirror stays 4-apart = safe, since
   fpga64.b00_fast ⟹ c64.sv.is_bank00 always):
   `b00_fast_read <= '1' when BANK00_FASTFIRE and supercpu_en='1' and cs_ram='1'
        and addr_hi_816=x"00" and cpuWe='0' and scpu_force_1mhz='0'
        and dma_active='0' else '0';`
4. **cpu_cyc: exclude bank-$00 READS** — add `and b00_fast_read='0'` to the three
   `cs_ram` main terms (CPU0/4/8/C) and the CPUC `cs_ram` sub-term. Writes
   (cpuWe=1 ⇒ b00_fast_read=0) still fire → BRAM write strobe preserved. When the
   constant is false, b00_fast_read='0' ⇒ bit-identical (Quartus folds it).
5. **enableCpu: new `BANK00_FASTFIRE` scheduler branch** (mirror the structure of
   the INTERNAL_FAST_FIRE / ALT_FIRE branches), placed as a new `elsif` BEFORE the
   ALT_FIRE branch:
   ```
   elsif BANK00_FASTFIRE and supercpu_en = '1' then
       if cpu_cyc_s(1) = '1' then                 -- MAIN: SuperRAM + bank-$00 writes + io
           enableCpu <= '1'; en_gap <= 0;
       elsif b00_fast_read = '1'                   -- FAST: bank-$00 read, BRAM matched-latency
             and en_gap >= 2                       -- honours C64.sdc -setup 2 -to *P65C816*
             and baLoc = '1' and cpu816_rdy_to_cpu = '1'
             and ( CPU0 | CPU2 | CPU4 | CPU6 | CPU8 | CPUA | CPUC )  -- NOT CPUE (consume wraps into EXT)
           then enableCpu <= '1'; en_gap <= 0;
       else enableCpu <= '0'; en_gap saturating+1;
       end if;
   ```
   No en_gap>=3 on MAIN here is WRONG — must keep the window-preserving guard.
   CORRECTION: MAIN here is the prefetch-tied pulse; bank-$00 reads no longer fire
   cpu_cyc so cpu_cyc_s(1) only ever carries SuperRAM/write/io ⇒ MAIN already only
   fires for real SDRAM accesses on their fixed cadence. The FAST branch's `en_gap`
   reset is what pushes a following SuperRAM cpu_cyc_s(1) to land ≥2 later. Keep
   MAIN unguarded (every real SDRAM consume must fire) but ADD `en_gap>=3` is
   unnecessary because cpu_cyc itself is throttled by busy_cnt="011". VET THIS.
6. **data_ready**: RDY_HANDSHAKE is OFF in the shipped config (`data_ready`
   inert '1', rdy = `baLoc and cpu816_rdy_to_cpu`), so NO data_ready change needed
   for the fast read — the fast branch gates on cpu816_rdy_to_cpu directly, same as
   INTERNAL_FAST_FIRE/ALT_FIRE. (If RDY_HANDSHAKE is ever enabled, add a
   `b00_fast_read` term to data_ready.)

### Open questions for Codex v3 red-team
- Q1: Does suppressing SDRAM ce for ALL bank-$00 reads (incl VIC badline @CYCLE_VIC0
  and REU C64-side reads) while serving them bram_q stay coherent? (Claim: yes —
  override keyed on is_bank00 so any ce-suppressed read gets bram_q; BRAM is
  authoritative; VIC/REU latch at their fixed slots and bram_q settles 1 clk64
  after a stable addr.)
- Q2: Is `cpuWe` the correct, stable read/write qualifier at the classifier
  (combinational with cpuAddr during the CPU slot)? Or must it be `cpuWe_pre` /
  qualified by vda_816?
- Q3: Does the FAST branch's `en_gap` reset (@CPU2) ever STARVE the MAIN
  cpu_cyc_s(1) consume of a following SuperRAM access, or double-fire enableCpu in
  the same period? (Trace says SuperRAM keeps its CPU4→CPU6 window; confirm no
  period where both a FAST and a cpu_cyc_s(1) want CPU on adjacent slots illegally.)
- Q4: At 2-apart, does continuous-read `bram_q` (1-clk64 latency off the live
  `c64_addr→scpu_sdram_addr→sdram_eff_addr` mux) settle before the consume edge,
  given the `-setup 2 -to *P65C816*` multicycle on cpuAddr? (STA will confirm; flag
  if the address mux makes the BRAM read addr arrive too late.)

---

## iter-31b RESOLUTION (2026-06-14) — native-only fast-fire SHIPPED

**Step-6 emu/turbo fast-fire (`03d9f2ee`) was HW-FALSIFIED.** Fine-grained capture
(`tools/lorenz_fine_capture.py`) + UART on the Lorenz scpu suite showed it ran the
CPU tests ~2.4-3× faster than control but **disrupted the KERNAL serial LOAD** that
chains the test programs (overlay PC stalled at `$ED5A`, the "LOAD wedge"). Plus emu
fast-fire changes the CPU-cycles-per-CIA-tick ratio, which would fail the
cycle-sensitive Lorenz CIA-timer tests. Path A (emu-fast) is not safely replicable.

**Root cause (two parts):** (1) fast-fire 2-apart ≈ 2× the SuperCPU design turbo
(4-apart), so cycle-counted bank-$00 timing loops (IEC serial bit-bang) desync;
(2) `emu_serial_throttle` was gated `emu_mode_816_i='1'`, but the **SCPU64 ROM
services the serial LOAD in NATIVE mode** ("native never runs serial" was FALSE), so
the throttle never fired and fast-fire leaked into serial.

**Fix (2 gated edits in `fpga64_sid_iec.vhd`, Codex-reviewed
`tools/codex-out/iter31b-native-only-review.txt`):**
1. `b00_fast_read` gains `emu_mode_816_i = '0'` ⇒ **fast-fire is native-only**. All
   emu-mode code (Lorenz 6502 test bodies, stock C64 SW, KERNAL/IEC) becomes
   behaviorally identical to control (reads still served by the authoritative BRAM =
   byte-equivalent, just at the 4-apart MAIN cadence). Doom runs native ⇒ keeps the
   full 38.8% win.
2. `emu_serial_throttle` drops the `emu_mode_816_i='1'` condition ⇒ forces 1MHz at
   `$00:$ED/$EE` in **both** modes ⇒ protects the native serial LOAD. Doom never
   executes $ED/$EE at runtime ⇒ no game impact.

**Build `41944346` (md5 41944346d0249c5ba0c420842e0de683), HW-validated A/B vs control
`3698680a`:** TNS=0 (setup +0.381); boot clean (idle $E5CD–$E5D6); Lorenz scpu now
matches control test-for-test and clears the step-6 serial wedge (lda→sta→ldx all
`-ok`, full 9-min run); Lorenz t65 bit-identical by construction (supercpu_en=
status[82]=0 in t65); Doom A/B identical to control (same engine frame, 125 UART
lines, native PC $2A55xx, fast-fire active). The emu 2.63× BASIC speedup is
intentionally given up — it was the compat-breaker. Native is the speed target; emu
is the compat target. **This is the first speed lever to ship after the dead set.**
