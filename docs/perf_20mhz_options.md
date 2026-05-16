# Pushing the MiSTer SuperCPU C64 fork toward 20 MHz

**Status (2026-05-16):** Effective CPU rate after the v347/`d930a81` MGL fix
is **4 MHz** (4 CPU slots per 32-tick sysCycle period, all 4 enabled by
turbo_m="111"). Target: the real CMD SuperCPU's nominal 20 MHz.

All RTL experiments below should land on a dedicated branch (suggested
`perf-experiments` off `vanilla-cpu-swap`) — adding caches / write
buffers / multi-domain clocks makes correctness debugging of every
unrelated bug dramatically harder, and the project's history (music_num
= -9, cache-coherence regressions on master) shows the cost.

## Quick state snapshot

- `clk_sys` = 32 MHz (PLL: 50 MHz → 31.527956 MHz via M=11 / div=18, fractional VCO)
- Other PLL outputs: `clk48` = 48 MHz (video), `clk64` = 63.055911 MHz (SDRAM)
- ALMs: 27,057 / 41,910 (65%) — area headroom available
- BRAM: 55% used
- PLLs: 3 / 6 (one spare)
- **Timing report**: `C64.sta.rpt` shows **-4.652 ns setup slack on clk_sys**,
  TNS -315 ns. Build "succeeds" only because Quartus emits a warning, not
  an error — the design is over budget on slow-silicon corners.
- sysCycle composition: EXT0–3 (4) + DMA0–3 (4) + EXT4–7 (4) + VIC0–3 (4) + CPU0–F (16) = 32 ticks
- CPU slots firing today: CPU0, CPU4, CPU8, CPUC (turbo_m="111") = 4 enables
- SDRAM controller (`sdram.v`): single-port, no burst (`BURST_LENGTH=3'b000`),
  no pipeline, no write buffer. ~7 clk64 (≈3.5 clk32) per access.
- 65C816 core: advances exactly 1 micro-cycle per CE pulse. No internal
  pipeline. STA long = 5 micro-cycles, of which cycles 3 and 4 are bus writes.
- RDY wait-state mechanism works (with the `rdy_gated <= rdy or not localWe`
  fix at `cpu_65c816.vhd:92` — RDY honored on reads, ignored on writes).

## Tier 0 — ✅ FIXED 2026-05-16: clk_sys timing closes via SDC multicycle

**Root cause:** The 30 worst paths all ran `sdram.dout_r[8/11]` → `P65C816.P[1]`
(SDRAM read → CPU Z flag), launched on clk64 (counter[1], 15.86 ns) and latched
on clk_sys (counter[2], 31.72 ns). Quartus analyzed this as a single-cycle
clk64→clk_sys crossing with 15.86 ns budget; the 18.19 ns data path missed
by -4.652 ns. 75 % of the delay was routing (interconnect), 25 % logic — i.e.
the fitter was placement-constrained at 72 % ALM utilization, not a deep
combinational logic problem. Release builds closed the same path with +2.317 ns
because lower ALM count (61 %) allowed tighter placement.

**Fix:** One SDC entry — multicycle setup=2 / hold=1 from clk64 to clk_sys.
Justification: the CPU consumer is gated by `enableCpu`, which only fires at
sysCycle CPU0/4/8/C (≥ 4 clk32 ticks apart = 8 clk64 ticks). SDRAM dout_r is
stable for the entire interval, so 2 clk_sys periods (63.4 ns) of budget is
always functionally safe. Mirrors the existing clk32→clk64 multicycle in the
reverse direction.

**Verified via incremental STA (no rebuild):** clk_sys worst slack jumped from
**-4.652 ns to +5.906 ns** (10.5 ns improvement). The new worst slack is on
OPL3 paths, unrelated to the SDRAM/CPU bottleneck. Hold paths remain positive
(+0.243 ns minimum). Full Quartus rebuild in flight as of commit landing.

**Files:** `C64.sdc` lines 21–38 (new block after the existing clk32→clk64
constraint).

**Effort:** 1 SDC line + STA re-run. **Speed gain:** unlocks tiers 1-6.

---

## Tier 1 — Reclaim idle sysCycle slots (cheap +1–4 MHz)

The audit of every sysCycle slot in `fpga64_sid_iec.vhd`:

| Slot range | Owner | Idle? | Repurposable? |
|---|---|---|---|
| EXT0, EXT1, EXT2 | IEC sample, DMA req latch, pixel pulse | No | No |
| **EXT3** | nothing | **Yes** | **YES (unconditional)** |
| DMA0–DMA3 | REU DMA bus | Only when `dma_active='1'` | **YES (conditional on `~dma_active`)** |
| EXT4 | refresh / sysEnable boundary | No | No |
| EXT5, EXT6 | DMA-req re-latch, pixel pulse | No | No |
| **EXT7** | nothing | **Yes** | **YES (unconditional)** |
| VIC0–VIC3 | VIC c/g-access pipeline | No | No |
| CPU0/4/8/C | already CPU enables | — | (already fires) |
| CPU1–3, 5–7, 9–B, D | CPU between micro-cycles | Yes-but | Maybe; see **Tier 4** |
| CPUE | second `enableVic` pulse | No | No |
| CPUF | CIA / SID positive-edge | No | No |

**Quick win**: fire `cpu_cyc` at EXT3 + EXT7 unconditionally + DMA0..3 when
`dma_active='0'`. That's 2 free slots + up to 4 conditional = +1 to +4 MHz.

**Caveat**: Doom's loader uses REU DMA heavily, so DMA slots are stolen
during the 60s post-launcher loader copy. Once Doom's runtime starts,
REU DMA is rare. So Tier 1 gives ~5–8 MHz effective.

**Effort:** 2–4 hours.
**Risk:** Need to be sure EXT3/EXT7 *really* have no consumers. Easy to
miss a hidden assignment; run with the debug pool and watch for VIC
glitches.

---

## Tier 2 — SDRAM write buffer (huge win for Doom)

Doom's JIT hot loop at `$2A:5598` is `LDA [$88],Y; STA [$8C]` — a byte
copy. Every `STA [$8C]` goes through `STATE_CMD_START → STATE_READ →
STATE_LAST` and stalls the next CPU enable on the SDRAM bus.

**Add a 1-deep write buffer** in `sdram.v`: latch address+data on `ce &
we`, ack the CPU immediately, drain to SDRAM in the background. The
next read must drain first (write-ack-before-read). This is exactly
how the real CMD SuperCPU's "CacheWrite" works (1-byte write buffer
per `docs/supercpu_architecture_reference.md`).

If the next CPU access is another write to a different address: queue
or stall. A 4-deep FIFO would eliminate stalls on Doom's hot loop
entirely.

**Effort:** 4–6 hours.
**Speed gain:** Doom hot loop should run at full CPU rate; per-loop
cycle count drops from ~9 clk32 to ~5 clk32 = ~+80% effective on
copy-heavy code. End-to-end Doom title-screen time should drop another
30–40% on top of Tier 1.
**Risk:** Write ordering bugs. Test cases: Lorenz suite must still
pass; specifically the immediate-load-after-write tests.

---

## Tier 3 — SDRAM burst-mode reads

`sdram.v` line 54: `localparam BURST_LENGTH = 3'b000`. The MT48LC16M16
supports 2/4/8-word bursts. With `BURST_LENGTH=3'b010` (4-word) and
matching state-machine rework, sequential reads (e.g., LDA-loops walking
through SuperRAM) cost 1 setup + N words instead of N × full-cycle.

**Effort:** 1–2 hours.
**Speed gain:** Smaller than Tier 2 for Doom (the hot loop isn't pure
sequential), but stacks with it. Bigger for code that does long block
copies.
**Risk:** Sequential-read assumption: if the 65C816's next access is
NOT contiguous, we waste the burst. Likely fine; CPU rarely runs 5+
random reads back-to-back.

---

## Tier 4 — More CPU slots per period (push to 8 MHz)

Beyond Tier 1's idle slots, the CPU window CYCLE_CPU0..CPUF has 12
remaining ticks where the 65C816 is "between micro-cycles". With
the SDRAM bottleneck fixed (Tiers 2+3), we can fire CE on every other
CPU sub-slot (CPU0, 2, 4, 6, 8, A, C, E) = 8 enables per 32 ticks =
**8 MHz**.

CPU core supports it: P65C816 has no minimum CE gap (audit of
`P65C816.vhd`). Practical ceiling stated by static-timing analysis:
~16 MHz CE rate is feasible before the combinational `NextState →
ADDR_BUS` path overflows one clk32.

**Effort:** 1–2 hours of RTL + revalidation.
**Speed gain:** Doubles CPU rate from 4 to 8 MHz.
**Risk:** Address-bus glitches if combinational paths can't settle
fast enough. Tier 0 (timing fix) is required first.

---

## Tier 5 — BRAM fast-path (16 MHz for bank-0 code)

The C64 motherboard 64KB lives in `c64_ram64k` BRAM. BRAM accesses
are single-cycle on Cyclone V. For any CPU access where the target is
bank-0 BRAM (and not I/O), pulse CE on every clk32 tick within the
CPU window.

**Architectural shape:**
- New signal `cpu_bram_hit` = `cs_ram & ~ext_cycle & ~vic_cycle & addr_hi=0`
- `cpu_cyc <= '1'` when `(sysCycle in CPU0..CPUF) and (cpu_bram_hit or original_turbo_logic)`
- Fall back to old gating on SDRAM hits (still stall waiting for SDRAM)

**Effort:** 6–10 hours (including buslogic mux work).
**Speed gain:** Bank-0 code = 16 MHz. SDRAM code (= most of Doom JIT) =
unchanged from Tier 4. **Limited Doom impact** because Doom runs almost
entirely from SuperRAM SDRAM, not bank-0 BRAM. Big win for vanilla
6510 software (rare in this fork), Lorenz tests, and KERNAL boot code.
**Risk:** Address-decode subtleties; missing a corner case where
"BRAM hit" actually requires a shadowed ROM.

---

## Tier 6 — Decouple CPU clock domain (the real path to 20 MHz)

Run the 65C816 from a dedicated, faster clock domain:

1. Use the one spare PLL output to generate a CPU clock — e.g., 96 MHz
   (3× clk_sys) or even 128 MHz. Cyclone V VCO is 600–1600 MHz so the
   fractional PLL can deliver this.
2. Add CDC handshake on the CPU's address/data bus to/from the 32 MHz
   sysCycle domain.
3. SDRAM controller already runs on `clk64`; either it stays there or
   moves to the new CPU clock.
4. RDY_IN stalls the CPU when the slow bus isn't ready.

**At 96 MHz CPU clock** with 1 CE pulse per CPU clock: 96 MHz effective.
65C816 STA long = 5 micro-cycles = ~52 ns vs VICE's 250 ns. **Faster
than VICE** in theory. In practice SDRAM and VIC sync brings it back
to ~16–20 MHz effective, matching the real CMD SuperCPU.

**Effort:** 30–50 hours.
- CDC bridge design + verification
- SDRAM arbitration in two-domain world
- VIC sync (VIC still needs 1 MHz reference)
- Timing closure on the new clock domain
- New SDC constraints
- Regression: full Lorenz + every cart we care about

**Risk:** High. CDC bugs are notoriously hard to reproduce. The reason
the master branch was suspect for years was over-aggressive caching;
adding a new clock domain is a strict superset of that complexity.

---

## Summary recommendation

| If you want… | Pick tiers | Effort | Effective rate |
|---|---|---|---|
| Stability first | 0 | 4–8 h | 4 MHz, but build closes timing |
| Quick 2× win | 0+1+2 | 12–20 h | 6–10 MHz, big Doom impact |
| Solid 8 MHz | 0+1+2+3+4 | 18–30 h | 8 MHz peak, 10 MHz on hot loops |
| 16 MHz bank-0 | 0+1+2+3+4+5 | 26–40 h | 8 MHz SDRAM, 16 MHz BRAM |
| Real 20 MHz | 0+2+3+6 | 40–60 h | 16–20 MHz effective |

**My read**: Tier 0+1+2 is the highest ROI by far — closes the current
timing gap AND attacks Doom's specific bottleneck (back-to-back
STA-long in the JIT hot loop) with ~15 hours of work. True 20 MHz via
Tier 6 is a multi-week project that earns Doom maybe another 2× over
Tier 2.

## Branch policy

All RTL changes from any of these tiers should live on a branch
**separate from** `vanilla-cpu-swap`. The master-branch history shows
that whenever caching/pipelining infrastructure was present, debugging
unrelated correctness bugs got harder because every regression was
"maybe the cache?". A clean `perf-experiments` branch lets you (a) keep
correctness debugging on `vanilla-cpu-swap` simple and reproducible,
and (b) rebase / drop the perf branch if a perf change turns out to
have introduced subtle bugs that hide other work.

Suggested workflow:
```
git checkout vanilla-cpu-swap
git checkout -b perf-experiments
# tier 0 commit, tier 1 commit, ...
# rebase / squash before merge if any tier lands
```

## Open items for whoever picks this up

- Identify the specific path causing -4.652 ns slack in
  `output_files/C64.sta.rpt` (Tier 0).
- Confirm whether MGL `<setname>` actually applied
  `C64_doomturbo.cfg` in the v349/`d930a81` test or if Doom wedged for
  another reason. The 09:53 test screenshot shows a crash trace at
  `$FF17`, not the expected attract render. Re-test before assuming
  Tier 0+ work landed cleanly.
- Doom has never reached in-game gameplay on this fork; all "Doom
  renders" milestones have been attract-mode title screens
  (`tools/doom_full/v342_DOOM_RENDERS.png`,
  `tools/doom_full/v347_post_test_now.png`). Reaching gameplay needs
  a key-press to dismiss the title and start the game — orthogonal to
  perf work, but useful as a "real" benchmark.
