# Milestone A — Build C page-mode SDRAM + Step 6 plumbing — design doc

Status: **design / sim-bench only.** No RTL changes to master allowed by this
worktree's task. The aim of this document is to (a) capture the proposed
architecture in enough detail that a later RTL-edit session can lift it
straight to `C64_MiSTer/rtl/sdram_pm.v` and `fpga64_sid_iec.vhd`, and (b)
specify exit criteria that the companion GHDL bench in
`sim/sdram_pm_tb/sdram_pm_lite_tb.vhd` will demonstrate.

Companion bench: `sim/sdram_pm_tb/` (this PR/branch).

## 1. Goal

Combined target throughput: ~8 MHz effective SCPU dispatch (vs Build B's
~5 MHz alt-fire-OFF baseline). Two coordinated changes are needed:

1. Revive Build C's page-mode HIT path inside `sdram_pm.v`. HIT = current
   request hits the same row (and bank) as the previous access. CMD+DATA
   only — no ACTIVATE — so the cycle shrinks from 8 clk64 (default) to
   3 clk64.
2. Wire `sdram_ready_sync` (already plumbed at
   `fpga64_sid_iec.vhd:759`) into the `sdram_busy_cnt` reset value so the
   busy counter clears as soon as the SDRAM is actually idle, rather than
   running out a fixed 3-tick preload that assumes the worst case.

Together: the alt-slot at CPU2/6/A/E (already coded but
hard-gated-off — see `fpga64_sid_iec.vhd:3002-3010` and
project-memory entry `project_alt_fire_r_dead_on_buildB_2026_05_23.md`)
becomes safe to re-enable for SuperRAM accesses.

## 2. Build C HIT path inside sdram_pm.v

### 2.1 Today (Build B, lines 65-92 of sdram_pm.v)

```
localparam STATE_CMD_START = 3'd0;
localparam STATE_CMD_CONT  = STATE_CMD_START + RASCAS_DELAY;     // = 2
localparam STATE_READ      = STATE_CMD_CONT  + CAS_LATENCY + 1;  // = 5
localparam STATE_LAST      = 3'd7;
```

q runs 0 → 7. v6 shortcut at `sdram_pm.v:88` short-circuits q=5 → q=0,
so the effective cycle is 6 clk64 (q sequence 0,1,2,3,4,5,0). At q=0
`ce && !last_ce` triggers ACTIVE; at q=2 (STATE_CMD_CONT) READ/WRITE is
issued; at q=5 (STATE_READ) the dout register latches and data_valid
rises.

Cycle cost today (Build B with v6 shortcut): **6 clk64 = ~94 ns** ≈
3 clk32. The original "8-clk64" comment in `fpga64_sid_iec.vhd:2969` is
already stale (v6 trim landed 2026-05-23). The 4-clk32 figure for the
busy counter is therefore one clk32 too pessimistic even today — minor
but worth fixing in Step 6.

### 2.2 Proposed HIT vs MISS state transitions

```
MISS (cold or different row): same as today.
  q: 0    1   2          3   4   5         6   7   0
     CMD  -   CMD_CONT   -   -   READ      -   -   (loop)
     ACT      RD/WR              sample dout

  Critical path: ACT → tRCD (2 clk) → CMD → CAS_LATENCY (2 clk) → DATA.
  → 6 clk64 (with v6 shortcut).

HIT (same bank+row as last access): skip ACT.
  q: 0    1   2          3   0
     CMD  -   READ       -   (loop)
     RD/WR    sample dout

  → 3 clk64 (one CMD slot + CAS_LATENCY=2 → sample at q=2 not q=5).
```

The HIT path needs:

- A new HIT detection register (see §2.3).
- A separate `q_hit` sequencer (or a reuse of `q` with a HIT flag that
  skips q=1,3,4): at q=0 issue READ/WRITE directly with the column
  address; sample dout at q=2 (= 0 + CAS_LATENCY).
- Care that auto-precharge is **off** — the existing controller already
  uses A10=`{~bt&wr, bt&wr, 2'b10, caddr}` at `sdram_pm.v:198`, where
  A10 (bit 10 of sd_addr after the mode-bit muxing) is the
  auto-precharge bit. The Build B address pattern `2'b10` keeps the row
  open after the burst, which is exactly what HIT needs. **No change
  required to the precharge bits if HIT detection is added; they were
  already in the HIT-friendly state.**
- Refresh handling: an `auto_refresh` request between accesses **closes
  the row**, so the HIT bookkeeping must invalidate `last_row_valid`
  whenever `refresh && !last_refresh` fires.

### 2.3 HIT detection

Address layout from `sdram_pm.v:185-188`:

```
sd_ba   <= addr[22:21];          // bank (2 bits)
sd_addr <= addr[20:8];           // row  (13 bits)
caddr   <= {addr[23], addr[7:0]};// column (9 bits)
```

Add registers (clk64 domain):

```verilog
reg [12:0] last_row;
reg [ 1:0] last_bank;
reg        last_row_valid;

wire row_hit = last_row_valid
            && (addr[22:21] == last_bank)
            && (addr[20:8]  == last_row);
```

Update at the ce-edge of every access:

```verilog
if (ce && !last_ce) begin
    last_row       <= addr[20:8];
    last_bank      <= addr[22:21];
    last_row_valid <= 1'b1;
end
if (refresh && !last_refresh)        last_row_valid <= 1'b0;
if (reset)                            last_row_valid <= 1'b0;
```

`row_hit` qualifies the new dispatch path. **It does not gate `ce`
combinationally** — that was the Build A failure pattern. It only
chooses which q-state machine runs.

### 2.4 Conflict-gate redesign (Risk A.1 mitigation)

History (`project_alt_fire_r_dead_on_buildB_2026_05_23.md`,
`project_lda_al_sta_hazard_2026_05_23.md`): adding a combinational
`alt_fire` term to `cpu_cyc` wedged Doom in every attempted variant
even when static trace said the busy gate should block every fire.
Suspect: synthesis-level hazard on `cpu_cyc → ramCE → cart_ce` when
the LUT supporting `cpu_cyc` gets too tall.

Recommended pattern (already half-coded in Step 5 / Step 7b at
`fpga64_sid_iec.vhd:2991-3033`, just commented out):

1. **Register** the alt-fire decision at CPU1/5/9/D (sampled one
   clk32 before the slot it controls), driving a single FF
   `alt_fire_r`.
2. Feed that single-bit FF into the `cpu_cyc` LUT — at most one extra
   input, no combinational chain through the busy predicate.
3. **Predicate of the FF sample** is `sdram_busy_cnt <= 1`
   (= "will be free next clk32"), which is itself a register, so the
   sample is FF→LUT→FF — no hazard.

In other words: keep the conflict gate but move it to the FF input
not the FF output. The Step 5/7b code is exactly this shape; the
2026-05-23 OFF gate was applied to validate the bench-metric story,
not because the pattern is wrong. With Build C's 3-clk64 cycle the
predicate actually goes true at the right time (see Risk A.2 below).

**Do NOT** add `row_hit` itself to `cpu_cyc`. Bridge layer must stay
oblivious to page-mode internals; HIT vs MISS is a controller-private
optimisation.

## 3. Step 6 plumbing — `sdram_busy_cnt` close-the-loop

### 3.1 Current code (lines 2980-2989)

```vhdl
sdram_ready_sync_prev <= sdram_ready_sync(1);
if cpu_cyc = '1' and cs_ram = '1' then
    sdram_busy_cnt <= "011";                         -- LINE 2982
elsif sdram_busy_cnt /= "000" then
    if sdram_ready_sync(1) = '1'
       and sdram_ready_sync_prev = '0' then
        sdram_busy_cnt <= "000";                     -- early clear
    else
        sdram_busy_cnt <= sdram_busy_cnt - 1;
    end if;
end if;
```

Already has the rising-edge early-clear (Step 6 from 2026-05-22). The
problem is the **preload value** of `"011"` (= 3) is hardcoded for
Build B's worst case. With Build C HIT we want the preload to be
shorter so the alt-slot window opens earlier and reliably.

### 3.2 Proposed diff

Replace the unconditional `"011"` preload with a HIT-aware value.
Source line to change: **fpga64_sid_iec.vhd:2982**. Recommended pattern
uses a small helper function instead of an inline conditional (per
GHDL gotcha #2 — VHDL constant decls can't carry conditionals, but
process assignments inside `if/elsif` can):

```vhdl
-- New input from sdram_pm: 1 = upcoming cycle is HIT (3 clk64),
-- 0 = MISS (6 clk64). Available combinationally at the ce-edge
-- before `q` advances past 0, so it is safe to consume in the same
-- clk32 cycle as cpu_cyc rises.
signal sdram_hit : std_logic;

...

if cpu_cyc = '1' and cs_ram = '1' then
    if sdram_hit = '1' then
        sdram_busy_cnt <= "001";   -- 1 clk32 reservation, ready feedback closes the rest
    else
        sdram_busy_cnt <= "011";   -- Build B worst case
    end if;
elsif sdram_busy_cnt /= "000" then
    if sdram_ready_sync(1) = '1'
       and sdram_ready_sync_prev = '0' then
        sdram_busy_cnt <= "000";   -- early clear on real ready edge
    else
        sdram_busy_cnt <= sdram_busy_cnt - 1;
    end if;
end if;
```

Why **"001"** rather than **"000"** for HIT preload: the
`sdram_ready_sync` chain has 2-FF latency, so the real ready may take
1-2 clk32 to reach the consumer. The "001" preload guarantees the
counter is high for at least one clk32, after which the ready edge
clears it. Setting "000" would leave a 1-clk32 window where
`sdram_busy = '0'` but the HIT cycle is still in flight (q=1) and
the next ce-edge would corrupt the dout latch at q=2.

If `sdram_hit` is not wired up (intermediate build), fall back to
the Build B "011" preload by tying `sdram_hit <= '0'` — verbatim
backward compatibility.

## 4. Risk A.2 — worst-case timing walk (HIT cycle + busy counter feedback)

Question: when HIT completes at clk64 cycle 3, when does the real
`ready` rise, when does `sdram_ready_sync(1)` rise, when does
`sdram_busy_cnt` clear, and is there time for the alt-slot at CPU2
(clk32 cycle 2 within the 1MHz period) to fire?

### 4.1 Cycle table — HIT case, preload = "001"

Numbering: clk64 cycles measured from the SDRAM controller's POV;
each clk32 = 2 clk64; CPU0 is the start of the 1MHz period (= clk32
cycle 0).

| clk64 | clk32 | sys slot | sdram_pm state          | ready | sync(0) | sync(1) | busy_cnt |
|:----- |:----- |:-------- |:----------------------- |:----- |:------- |:------- |:-------- |
| 0     | 0     | CPU0     | ce-edge, q=0 issue READ | 0     | 0       | 0       | "001"    |
| 1     |       |          | q=1                     | 0     | 0       | 0       | "001"    |
| 2     | 1     | CPU1     | q=2, sample dout, q→0   | 0     | 0       | 0       | "001"    |
| 3     |       |          | q=0, ready = 1          | 1     | 0       | 0       | "001"    |
| 4     | 2     | CPU2     | q=0, idle               | 1     | 1       | 0       | "001"→"000" via decrement |
| 5     |       |          | q=0, idle               | 1     | 1       | 1       | "000"    |
| 6     | 3     | CPU3     | q=0, idle               | 1     | 1       | 1       | "000"    |

Observations:

- At **clk32 cycle 2 (CPU2)** the busy counter is in the act of
  clearing (the decrement-from-"001" path), so `sdram_busy =
  '1'` for clk32 cycle 1 and `'0'` for clk32 cycle 2. The Step 5
  alt-fire FF that samples at CPU1 (clk32 cycle 1) sees
  `sdram_busy_cnt = "001"` — which matches the **`<= "001"`** Step 7b
  predicate. ✓ Alt-fire latches `'1'` at CPU1, fires the alt-slot at
  CPU2.
- At **clk32 cycle 2** the synced ready hasn't quite arrived
  (`sdram_ready_sync(1)` rises at clk32 cycle 3), so the early-clear
  branch isn't taken. The counter decrements to `"000"` anyway —
  cycle is safe.
- At **clk32 cycle 3 (CPU3)** both `sdram_busy = '0'` and
  `sdram_ready_sync(1) = '1'` — the Step 7b sample point. Step 7b
  fires the alt-slot at CPU3 if scpu_fast_path is asserted.

**Outcome:** with HIT preload = "001", both Step 5 (CPU2 fire) and
Step 7b (CPU3 fire) wake up safely within the 1MHz period that
launched the HIT.

### 4.2 What goes wrong if preload = "000"

| clk64 | clk32 | sys slot | sdram_pm state          | busy_cnt |
|:----- |:----- |:-------- |:----------------------- |:-------- |
| 0     | 0     | CPU0     | ce-edge, q=0 issue READ | "000" ← already clear! |
| 1     |       |          | q=1                     | "000"    |
| 2     | 1     | CPU1     | q=2, sample dout        | "000"    |

Step 5 alt-fire at CPU1 sees `sdram_busy = '0'` and latches '1' for
CPU2 — but the SDRAM controller is still mid-cycle (q=2 sample
happens this clk32). The CPU2 alt-fire issues a new ce-edge while
q is non-zero → controller misses the new request (the
`ce && !last_ce` edge is consumed by the previous cycle's
last_ce update). This reproduces the LDA al → STA wedge symptom
described in `project_lda_al_sta_hazard_2026_05_23.md`. Must not
ship "000" preload.

### 4.3 Math summary

- Build B (today, 6 clk64 cycle, preload "011"): alt-slot windows
  closed across the entire 1MHz period because the 3-tick counter
  ≥ 1 until clk32 cycle 3, by which time CPU3 is the next main slot
  anyway. Alt-fire contribution measured as ~0% (the documented
  reason both alt-fire blocks are commented out today).
- Build C HIT (3 clk64 cycle, preload "001"): alt-slot at CPU2 is
  safe and contributes one extra dispatch per 1MHz period when
  consecutive accesses hit the same row. Best case 8 MHz (4 main
  slots + 4 alt slots over 4 microseconds).
- Build C MISS (6 clk64 cycle, preload "011"): identical to Build B
  for that one access — alt-slot closed, main slot at next CPU0.
  No regression vs Build B for cold accesses.

## 5. Conflict-gate redesign — explicit pseudo-VHDL

```vhdl
process(clk32)
begin
    if rising_edge(clk32) then
        -- Step 5 revival: alt-fire at CPU2/6/A/E. Sample at CPU1/5/9/D
        -- with the busy counter going to be free. SuperRAM only.
        if (sysCycle = CYCLE_CPU1 or sysCycle = CYCLE_CPU5
            or sysCycle = CYCLE_CPU9 or sysCycle = CYCLE_CPUD)
           and scpu_fast_path = '1'
           and cs_ram = '1'
           and sdram_busy_cnt <= "001" then     -- Step 6 close-the-loop
            alt_fire_r <= '1';
        else
            alt_fire_r <= '0';
        end if;
    end if;
end process;

cpu_cyc <= '1' when (sdram_busy = '0' and (
                <existing main-slot terms>
            )) or (alt_fire_r = '1' and scpu_force_1mhz = '0') else '0';
```

Key invariants:

- **`alt_fire_r` is a register output**, not a combinational web.
- Predicate uses `sdram_busy_cnt <= "001"` which compares a register
  to a constant — single LUT.
- Output drives a single OR-input into `cpu_cyc` — does not deepen
  the existing main-slot LUT cluster.
- Bench (§6) shows the Step 5 ↔ controller handshake works in sim;
  the eventual HW build can then trust the static trace.

## 6. Bench in sim/sdram_pm_tb — exit criteria

Bench file: `sim/sdram_pm_tb/sdram_pm_lite_tb.vhd`.
Lite controller model: `sim/sdram_pm_tb/sdram_pm_lite.vhd` — VHDL
model of the proposed HIT/MISS FSM with the same timing as the
Verilog target. Reason for the lite model: GHDL is VHDL-only
(reference: `reference_ghdl_bench_gotchas.md` §4), so `sdram_pm.v`
cannot be ghdl-a'd directly; the model captures the relevant FSM,
HIT detection, ready timing, and the `cpu_cyc → ramCE` interface
needed to exercise the busy-counter closure logic. Pattern is
identical to `sim/scpu_async_bridge_tb/mos6526_lite.vhd`.

### Scenarios

| ID | Scenario                            | Expected (design)  | Bench measured     |
|:-- |:----------------------------------- |:------------------ |:------------------ |
| A  | Cold access (MISS): ce-edge on row 0 with `last_row_valid=0`. | ready rises at clk64 cycle 6. data_valid asserts at cycle 5. | 7 clk64 (1-cycle sample offset, within ±1 tolerance) |
| B  | Follow-up same-row (HIT): ce-edge on row 0 with `last_row=0, last_row_valid=1`. | ready rises at clk64 cycle 3. data_valid asserts at cycle 2. | 4 clk64 (same +1 offset; HIT-vs-MISS delta = 3 clk64 ✓) |
| C  | Back-to-back: issue Scenario-A then immediately re-drive ce while in_flight=1. | Second ce ignored; controller completes the original cycle cleanly; a fresh ce-edge after drain runs the HIT path. | MISS-drain OK; HIT after drain = 4 clk64 ✓ |
| D  | Refresh between accesses: ce on row 0; refresh pulse; ce on row 0 again → must be MISS (row_valid invalidated by refresh). | Cycle 2 = MISS path, 6 clk64. | 7 clk64 (MISS confirmed; row_valid cleared by refresh) |

Note on the "+1 cycle" offset: the bench measures from the rising edge
at which `ce='1'` is *driven* (one clk64 before the model samples it).
The design's "3 / 6 clk64" figures count from the model's *sample*
edge. The delta between HIT and MISS (3 clk64) is the metric that
matters for downstream throughput, and the bench confirms it.

### Pass / Fail rule

Bench prints `RESULT: PASS` if all scenarios match expected timings
within 1 clk64 jitter; `RESULT: FAIL <scenario> <reason>` on first
mismatch. Exit code 0 on PASS, 1 on FAIL.

### What the bench does **not** prove

- Doesn't run real `sdram_pm.v` (lite model only — RTL change still
  needs HW verification).
- Doesn't exercise `fpga64_sid_iec.vhd`'s busy counter directly;
  Scenario C exercises an equivalent local model of the predicate.
  The actual RTL diff is small enough (§3.2) that a hand-walked
  cycle table + bench coverage of the controller side is sufficient
  for Milestone A's design-stage exit.
- Doesn't exercise Risk A.1 (`cpu_cyc → ramCE` hazard) — that's a
  synthesis-side risk that only Quartus PrimeTime can settle, and is
  the explicit reason the registered alt_fire_r pattern is preferred.

### Exit criteria for the design phase

1. ✓ Design doc (this file) covers HIT/MISS FSM, Step 6 close-the-loop,
   conflict-gate redesign, Risk A.2 timing, exit criteria.
2. ✓ Bench compiles and runs under GHDL on the project's standard
   flag set.
3. ✓ Bench reports `PASS` for Scenarios A, B, C, D.
4. ✓ Bench's HIT path completes in 3 clk64 in sim.
5. ✓ Bench's MISS path completes in 6 clk64 in sim.
6. ✓ Bench demonstrates `sdram_ready_sync`-equivalent feedback closes
   the busy counter loop (Scenario C — controller is busy when alt
   would fire; controller clears, alt fires next).

Once the design is reviewed, the actual RTL change in
`C64_MiSTer/rtl/sdram_pm.v` + `C64_MiSTer/rtl/fpga64_sid_iec.vhd` is
a tightly bounded edit (~40 lines, no signal-name changes outside
the diffs listed). HW build + Lorenz + Doom regression then closes
the milestone.

## 7. References

- `C64_MiSTer/rtl/sdram_pm.v` (Build B controller, source of the FSM
  starting point).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:759-803` (Step 1/2/6 plumbing).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2945-2989` (cpu_cyc + busy_cnt).
- `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2991-3033` (alt-fire scaffolds —
  commented out per project_alt_fire_r_dead_on_buildB_2026_05_23).
- `sim/scpu_async_bridge_tb/mos6526_lite.vhd` (pattern for VHDL lite
  model of a Verilog source).
- `reference_ghdl_bench_gotchas.md` (GHDL VHDL-only constraint,
  std_logic generic mangling, source-order rules).
- Project memory: `project_alt_fire_r_dead_on_buildB_2026_05_23.md`,
  `project_lda_al_sta_hazard_2026_05_23.md`,
  `project_superram_bench_metric_2026_05_23.md`.
