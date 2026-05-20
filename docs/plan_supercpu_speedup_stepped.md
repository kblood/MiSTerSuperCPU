# Stepped Speedup Plan (post page-mode investigation, 2026-05-20)

## Context

Page-mode SDRAM (Build C) was shelved because the CONFLICT path needs 7
clk64 cycles but the bus arbiter only gives 6 to `enableCpu`. The
deeper investigation (memory `project_sdram_page_mode_needs_layer2.md`)
identified that **the real bottleneck for Doom isn't SDRAM at all** —
it's the 4 MHz cap on `enableCpu_816`. SDRAM page-mode would shave
~30% off SDRAM access time; lifting the 4 MHz cap could deliver 2-4×.

STA experiment 2026-05-20 (this session) confirmed:
- Removing the P65C816 multicycle-2 SDC constraint pushes clk_sys
  into -0.880 ns slack (TNS -12.451 ns).
- All 30 violating paths converge on **ONE chain**: `AddrGen|AAL[1]`
  (address-adder low bit) or `ADDR_INC[1]~0` → `AddrGen|PCr[0..10]`
  (Program Counter) and `P[1]` (Z flag).
- So "Option C as drafted" (fire CPU enable on every CPU slot) doesn't
  close timing on the existing netlist. Two viable mitigations:
  - **Mitigation A**: fire on EVERY OTHER slot → 8 MHz effective →
    preserves multicycle-2 → no timing risk → 2× Doom.
  - **Mitigation B**: refactor the AAL→PCr path (register the address
    increment) → unlocks full 16-slot Option C → 4× Doom.

Real CMD SuperCPU Doom runs at "virtually unplayable single-digit
frame rate" (DoomWiki) — so 6 fps from Mitigation A *already exceeds*
real hardware. Mitigation B becomes optional polish.

## Six-step plan, each independently verifiable

### Step 1 — Layer 2: cpu_cyc backpressure on sdram_ready
**Files touched:** `fpga64_sid_iec.vhd` (cpu_cyc gating + sync FFs),
`c64.sv` (already exposes sdram_ready, no change needed).

**RTL change sketch:**
```vhdl
-- New: 2-FF synchronizer to bring sdram_ready (clk64 domain)
-- into clk32 domain.
signal sdram_ready_sync : std_logic_vector(1 downto 0);
process(clk32) begin
  if rising_edge(clk32) then
    sdram_ready_sync <= sdram_ready_sync(0) & sdram_ready;
  end if;
end process;

-- New: predicate "would the upcoming CPU slot route through SDRAM".
signal cpu_needs_sdram : std_logic;
cpu_needs_sdram <= '1' when
    cs_ram = '1' and (
      (supercpu_en = '1' and addr_hi_816 /= x"00") or  -- SuperRAM
      (cart_active = '1')                             -- cartridge ROM
    ) else '0';

-- Modified: gate the existing cpu_cyc term on backpressure.
cpu_cyc <= '1' when
    ((cpu_needs_sdram = '0') or (sdram_ready_sync(1) = '1')) and
    (
      (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1'))
    ) else '0';
```

**Expected effect on the *current* build:** zero observable change.
Today's enable cadence (max once per 4 clk32) is far slower than the
SDRAM's 5-cycle baseline access, so `sdram_ready_sync` is always '1'
when cpu_cyc would fire. The gate is a no-op until Step 2 increases
enable frequency.

**Pass criteria:**
- Lorenz t65 32 min → matches v356 baseline (`andix - ok` or further).
- Lorenz scpu 32 min → matches v356 baseline.
- Doom v356 PLAY recipe → reaches 3D rendered E1M1.
- Wolf3D menu → reaches Level 1 starting room.
- Timing closure ≥ baseline (no new violations).

**Rollback:** single commit revert.

### Step 2 — Option C Mitigation A: alternate-slot SCPU fast-path
**Files touched:** `fpga64_sid_iec.vhd` (extra `cpu_cyc` term).

**RTL change sketch:**
```vhdl
-- "True" only when the SCPU CPU core is fetching from SuperRAM
-- and not touching I/O — safe to give it extra slots.
signal scpu_fast_path : std_logic;
scpu_fast_path <= '1' when
    supercpu_en = '1' and addr_hi_816 /= x"00"
    and cs_io = '0' and dma_active = '0' else '0';

cpu_cyc <= '1' when
    ((cpu_needs_sdram = '0') or (sdram_ready_sync(1) = '1')) and
    (
      -- existing 4-MHz baseline terms (unchanged)
      (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1')) or
      -- NEW alternate-slot fast path (8 extra MHz)
      (scpu_fast_path = '1' and (
         sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU6 or
         sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUE
      ))
    ) else '0';
```

This keeps enables ≥ 2 clk32 apart (CPU0→CPU2 = 2, CPU2→CPU4 = 2,
etc.) so the existing multicycle-2 SDC constraint stays valid → no
timing closure surprises.

**Expected:** ~2× SuperRAM throughput when SCPU is executing in
banks ≠ $00 → Doom should reach ~6 fps (vs 3 today). Bank-$00 +
I/O still at 4 MHz (preserves VIC/CIA semantics).

**Pass criteria:**
- Lorenz t65 + scpu unchanged (Lorenz runs in bank $00 → fast-path
  shouldn't fire).
- Doom progression hashes pre-Mitigation: hashes flip every ~30 s
  through ~t=120s. Post-Mitigation: same sequence, ~half the time
  per hash transition.
- Wolf3D menu nav reaches Level 1 in less time than v356.

**Rollback:** single commit revert.

### Step 3 — Measurement gate
Run `tools/doom_v356_PLAY.py` with extended capture, compare per-hash
timing v356 vs Step 2. Run SCPU speed bench. If <1.5× speedup, stop
and instrument `scpu_fast_path` on UART column to verify firing rate
before going to Step 4.

### Step 4 (optional) — Mitigation B: P65C816 carry-chain refactor
Pipeline `AAL→PCr` via an intermediate register. Removes the critical
path; allows firing on ALL 16 CPU slots → 4× speedup.

**Files touched:** `rtl/65C816/AddrGen.vhd` (or equivalent — needs
investigation first).

**Risk:** high. Touches CPU semantics. Must verify against:
- GHDL `sim/p65c816_tb` (must still pass).
- Lorenz scpu mode (must still pass).
- Doom + Wolf3D regression.

**Gate:** only attempt if Mitigation A's 2× isn't enough.

### Step 5 (optional) — re-enable Build C page-mode SDRAM
With Layer 2 from Step 1 in place, Build C's CONFLICT stalls are safe
(CPU waits instead of reading stale dout). Cherry-pick `50d8bd3` onto
HEAD.

**Expected:** 10-20% additional SuperRAM throughput on HIT-friendly
patterns (sequential code, large texture reads).

### Step 6 (optional) — bank striping on bank-$00 RAM
Put `c64_addr[9:8]` into `sd_ba` for the bank-$00 case. Reduces
CONFLICT frequency further (ZP↔stack no longer collide).

## Decision tree at each gate

- After Step 1: Lorenz pass? → Step 2. Lorenz fail? → revert and
  debug; do NOT proceed (correctness foundation broken).
- After Step 2: 2× speedup measured? → consider STOP (we beat real
  HW). <2×? → instrument and debug fast-path firing rate.
- After Step 3: user input on whether to pursue Step 4+.

## Cross-cutting concerns

- **Shared MiSTer cooperation:** check `/tmp/CORENAME` ownership
  before each deploy (`docs/agent-cooperation.md`).
- **No new builds into `/media/fat/_Computer/`** — only `/_Test/C64.rbf`.
- **Each step on its own git commit** for clean revert.
- **Doom regression check** is the canonical functional smoke after
  every step.
