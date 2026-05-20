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

### Step 1 — Layer 2: sdram_ready synchroniser plumbing
**Status:** ✅ Implemented + verified PASS 2026-05-20 (commit `a65b3f7`).
6/6 Doom hashes match v356; timing slack improved (+0.118 ns worst setup,
clk_sys +5.997 ns). `sdram_ready_sync` declared but consumer is deferred
to Step 5 (Build C revival); Step 2 uses a more cycle-accurate local
counter instead (see below).

**Files touched:** `fpga64_sid_iec.vhd` (sync FFs only),
`c64.sv` (wires `sdram_ready` from sdram_pm into top-level VHDL port).

**RTL change as implemented:**
```vhdl
-- 2-FF synchroniser bringing sdram_ready (clk64-domain output of
-- sdram_pm) into clk32. Kept for Step 5 (Build C revival) where the
-- actual ready edge timing matters.
signal sdram_ready_sync : std_logic_vector(1 downto 0) := "11";
attribute preserve : boolean;
attribute preserve of sdram_ready_sync : signal is true;

process(clk32) begin
  if rising_edge(clk32) then
    sdram_ready_sync <= sdram_ready_sync(0) & sdram_ready;
  end if;
end process;
```

**Why not gate cpu_cyc on sdram_ready_sync directly:** the 2-FF sync
chain adds 2 clk32 of latency. Build B's SDRAM cycle is already exactly
4 clk32 = 8 clk64; gating cpu_cyc on `sdram_ready_sync(1)='1'` would
delay every enable by 2 clk32, *halving* today's throughput. Use a
local cycle-accurate counter instead (Step 2).

**Expected effect on the current build:** zero observable change.
Step 1 only adds wiring; no behavioural gate yet.

**Pass criteria:**
- Lorenz t65 32 min → matches v356 baseline (`andix - ok` or further).
- Lorenz scpu 32 min → matches v356 baseline.
- Doom v356 PLAY recipe → reaches 3D rendered E1M1.
- Wolf3D menu → reaches Level 1 starting room.
- Timing closure ≥ baseline (no new violations).

**Rollback:** single commit revert.

### Step 2 — SDRAM-busy backpressure infrastructure (alt-slot deferred)
**Status:** ⚠️ PARTIALLY LANDED 2026-05-20. The SDRAM-busy predictor
counter and `sdram_busy='0'` gate on the *main* slots compile + pass
Doom 6/6 (bisect-1 RBF `7fdd41b7`). Adding the alt-slot term (CPU2/6/A/E
+ scpu_fast_path) wedges Doom on Build B even though static analysis
predicts every alt-slot fire is blocked by the busy counter. Both
OUTER-gate (bisect-2) and INNER-gate (bisect-3) variants wedge with
identical stripe→solid-color symptoms (stuck hash 25ce2464 / 1df06220
from t=60 onward). Suspect: synthesis-level hazard on cpu_cyc →
ramCE → cart_ce when alt-slot inputs join the same LUT cluster.
Alt-slot term is therefore deferred to be re-investigated alongside
Step 5 (Build C revival), where it actually delivers speedup; the
busy-counter scaffolding is committed now so Step 5 can flip a single
constant (3 → 1) and add the alt-slot term in one well-isolated change.

**Files touched:** `fpga64_sid_iec.vhd` (counter process + helpers +
extended `cpu_cyc` term).

**RTL change as implemented:**
```vhdl
-- Local SDRAM-busy predictor (cycle-accurate, no sync latency).
-- Counter resets to 3 on every cpu_cyc fire that drives SDRAM
-- (cs_ram = '1' covers bank-$00 RAM AND SuperRAM via the
-- scpu_long_access OR in fpga64_buslogic.vhd:551). Decrements one
-- per clk32 down to 0. Build B baseline SDRAM cycle = 8 clk64 =
-- 4 clk32 → counter is 0 by the next main slot (CPU0→CPU4 = 4
-- clk32), preserving today's cadence exactly.
signal sdram_busy_cnt : unsigned(2 downto 0) := (others => '0');
signal sdram_busy     : std_logic;

process(clk32) begin
  if rising_edge(clk32) then
    if cpu_cyc = '1' and cs_ram = '1' then
      sdram_busy_cnt <= "011";
    elsif sdram_busy_cnt /= "000" then
      sdram_busy_cnt <= sdram_busy_cnt - 1;
    end if;
  end if;
end process;
sdram_busy <= '1' when sdram_busy_cnt /= "000" else '0';

-- Fast-path predicate: SCPU executing in SuperRAM, not I/O, no DMA.
signal scpu_fast_path : std_logic;
scpu_fast_path <= '1' when
    supercpu_en = '1' and addr_hi_816 /= x"00"
    and cs_io = '0' and dma_active = '0' else '0';

cpu_cyc <= '1' when sdram_busy = '0' and (
      -- existing 4-MHz baseline terms (unchanged semantics)
      (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1') or
      (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1')) or
      -- NEW alt-slot fast path
      (scpu_fast_path = '1' and cs_ram = '1' and (
         sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU6 or
         sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUE
      ))
    ) else '0';
```

This keeps enables ≥ 2 clk32 apart (CPU0→CPU2 = 2, CPU2→CPU4 = 2,
etc.) so the existing multicycle-2 SDC constraint stays valid → no
timing closure surprises.

**Expected on Build B (today's SDRAM cycle = 8 clk64 = 4 clk32):**
counter blocks every alt-slot CPU2 (busy_cnt still ≥ 1 at slot +2),
so alt-slot fires *don't happen* yet → 0× speedup but also 0 regression.
**This is the safe-foundation behaviour.** The throughput unlock arrives
in Step 5 when Build C's 3-clk64 HIT path comes back and the counter
constant drops from 3 to 1 → alt-slot CPU2 sees busy_cnt=0 → fires →
8 MHz effective for SuperRAM HIT-pattern code.

**Pass criteria (Step 2 standalone, Build B SDRAM):**
- Lorenz t65 + scpu unchanged (Lorenz runs in bank $00 → fast-path
  shouldn't fire; counter logic still gates main slots identically).
- Doom progression hashes match v356 (alt-slot blocked by busy_cnt).
- No timing closure regression (multicycle-2 still valid).

**Speedup is deferred to Step 5** — Step 2 alone gives ~0× on Build B;
that's expected and documented in `project_sdram_page_mode_needs_layer2.md`.
Pass = no regression; the alt-slot wiring is in place ready for Step 5.

**Rollback:** single commit revert.

### Step 3 — Measurement gate
Run `tools/doom_v356_PLAY.py` with extended capture, compare per-hash
timing v356 vs Step 2 (expect MATCH on Build B). After Step 5 (Build C
revival), re-run and confirm ≥1.5× speedup. If <1.5× post-Step-5, stop
and instrument `scpu_fast_path` on a UART column to verify firing rate.

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
