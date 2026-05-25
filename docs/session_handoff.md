# Session handoff — 2026-05-26 (late evening): mb-probe-003 misdiagnosis pivot

## 0. TL;DR (revised)

The handoff from earlier today framed the mb-probe-003 result as
"irq_n stuck low → CPU stuck in KERNAL raster-wait loop at $EAB1+
polling $D012". **That framing is wrong on two counts**, and the
correct picture changes the whole next-step:

1. **$EAB1+ in KERNAL ROM is the SCNKEY keyboard-scan de-bounce
   loop, not a $D012 raster-wait.** Disassembled bytes from
   `kernal.901227-03.bin`:
   - `$EAAB: LDA $DC01` / `$EAAE: CMP $DC01` / `$EAB1: BNE $EAAB`
     (keyboard column de-bounce; reads CIA1 PRB twice and retries
     if they differ)
   - `$EAB3..$EAD2`: column-bit decode + KEYTAB lookup
   - `$EAD4..$EADA`: row-mask rotate (SEC+ROL) + write $DC00
   - `$EADC`: SCNKEY exit (PLA + JMP ($028F))
   - IRQ tail at `$EA7B` does `JSR $EA87` (SCNKEY), then `$EA7E
     LDA $DC0D` (ack CIA1), then RTI.
   - **Only $D012 references in entire KERNAL: $E785, $E84C, $FF5E.
     None near $EAB1+.**
2. **Screenshots of mb-probe-003 final state show `?DEVICE NOT
   PRESENT ERROR` in all 3 runs**, not a black-screen wedge:
   - Run 1: clean error message + `READY.` (no wedge)
   - Run 2: only `?DEVICE` printed, hung mid-message (the
     classifier-labelled "wedge")
   - Run 3: clean error message + `READY.` (no wedge)
   - i.e. **LOAD"*",8,1 fails in every run** because drive 8 doesn't
     respond to IEC LISTEN. The "wedge" stochasticity is about
     whether the **error-recovery print** completes or hangs.

So the actual bug is **MCP-specific CIA2 IEC failure**:
KERNAL writes to CIA2 PRA ($DD00) that should drive ATN/CLK/DATA
on the IEC bus aren't producing visible bus activity. CIA2 PA stays
stable at $97 during the entire wedge SECOND_HALF, vs cycling
through `{$0F,$27,$47,$A7,$C7}` in the working passthrough+gates
baseline ([[passthrough-plus-gates-baseline-2026-05-25]]). This is
the same bug that drove v8 to disable MCP entirely in 2026-05-24
([[v8-passthrough-iec-fix-2026-05-24]]). v13g's
`cia2_write_safe = vpa OR vda OR vpa_d1 OR vda_d1` widened the
write gate by 1 clk_sys but apparently still misses some real
CIA2 writes.

## 1. State at end of session

- **Source:** committed at `945e94b` (mb-probe-003) +
  `b6a0207` (RTL probes). Working tree clean (only
  ignored test artifacts).
- **MiSTer (`192.168.50.130`):** still running mb-probe-003 RBF
  (md5 `ef01bea6`), lockfile held for C64. No state-changing
  actions taken this turn.
- **Memory:** new entry `project_mb_probe_003_misdiagnosis_pivot.md`
  captures the re-characterization. Old memories
  `project_mb_probe_003_irq_n_stuck_confirmed.md` and
  `project_irq_n_stuck_low_hypothesis.md` are still accurate at
  the mechanism level (Timer A keeps firing; icr[0] stays set;
  irq_n stuck low until $DC0D read) but their FRAMING ("CPU
  stuck in KERNAL raster-wait") is wrong — those mechanism
  observations are downstream symptoms of BASIC stuck in
  SEI'd error-print code.
- **Codex review** (~50k tokens, 8 min wall): independently
  confirmed the $DC01 bus path is statically clean (no
  bad-mux). Output saved to `/tmp/codex_probe004_out.txt`.
  Briefed on the OLD SCNKEY hypothesis so it ranked M1
  (de-bounce loop wedge) as #1 — that ranking is no longer
  relevant because SCNKEY isn't the wedge site.

## 2. Recommended next probe — REVISED

**The cheapest next step is NOT another Quartus build.** It is a
deploy-only verification:

### 2.1 Deploy passthrough+gates RBF and rerun LOAD

Deploy the archived [[passthrough-plus-gates-baseline-2026-05-25]]
RBF (md5 `8a7489ef`) to `/media/fat/_Test/C64.rbf` and run the
same LOAD"*",8,1 test. Expected results, in order of
informativeness:

- **LOAD succeeds + READY.** → confirms MCP-specific CIA2 write
  loss. The CIA2 write path is the only thing that differs
  between MCP and passthrough at the CIA2-instantiation level.
  This gives strong evidence to either (a) widen v13g further
  / redesign the gate, or (b) accept passthrough as ship
  baseline.
- **LOAD also fails with DEVICE NOT PRESENT.** → falsifies the
  MCP-specific hypothesis. Something else regressed since
  2026-05-25 (Milestone A Option (a) silicon changes? new probes?).
  Bisect needed.

This is ~5 min of work (MGL swap, screenshot at t+30s) vs ~40
min for a Quartus probe build. Do this FIRST.

### 2.2 If MCP-specific (LOAD works in passthrough): mb-probe-004

Probe CIA2/IEC, not CIA1/SCNKEY. Minimum useful taps:

- **CIA2 PRA write counter** per frame (count `cs_cia2='1' &
  cpuWe='1' & cpuAddr[3:0]=$00`). If 0 during LOAD, writes
  blocked. Compare against unconditional `(cs_cia2='1' &
  cpuWe='1')` to see how many writes the v13g gate is rejecting.
- **CIA2 PRA last 4 written values** (ring buffer) — lets us
  see whether KERNAL's LISTEN sequence ($20/$30/$3F etc.)
  reaches the CIA at all.
- **IEC bus snapshot**: `iec_atn_o`, `iec_clk_o`, `iec_data_o`,
  `iec_data_i`, `iec_clk_i` at vblank.

LINE_LEN budget: 402 → ~440. Each new tap risks more Quartus
P&R drift, so design tightly.

### 2.3 If not MCP-specific (LOAD fails in passthrough too): bisect

Either Option (a) silicon (Milestone A) regressed CIA2 IEC under
LOAD, or the milestone-b probes themselves did. Use git bisect
between `cf8d185b` (Milestone A Option (a) silicon-validated,
LOAD"*" passed) and current `945e94b`.

### 2.4 The MCP failure is documented + a known limitation

Found in `fpga64_sid_iec.vhd` lines 3082-3088, written 2026-05-24:

> scpu_force_1mhz throttles cpu_cyc to a single CYCLE_CPUC slot
> per 1MHz period when software asserts $D072 (system 1MHz) or
> $D07A (SCPU 1MHz). Required so KERNAL IEC byte-receive ($EEAF)
> gets stock 1MHz CIA2 timing — without this, LOAD"*",8,1 wedges
> on the F.3' bridge (~3MHz effective).

So the wedge we just rediscovered is **the same wedge documented at
build time** — when running under turbo MCP, KERNAL's IEC
byte-receive loop is too fast for CIA2's expected 1MHz cadence,
and bytes are lost. The fix already in the source requires the
running software to assert $D072/$D07A first. Stock C64 KERNAL
LOAD doesn't know about SuperCPU registers, so the throttle never
activates, and LOAD wedges every time.

Three possible permanent fixes:

(a) **Auto-throttle on $DD00 access.** When the SCPU writes to
    any CIA2 PRA register, hardware-force `scpu_force_1mhz='1'`
    for N CPU cycles afterward. Self-arms on IEC, self-disarms
    after timeout. Real CMD SuperCPU does this via firmware; we
    can do it in RTL because we don't have the SCPU OS image.

(b) **Wrap LOAD with a $D072 POKE.** The kickstart/launcher can
    add `POKE $D072,0` before LOAD and restore after. Operator-
    visible and requires user discipline.

(c) **Ship passthrough as default; document MCP as experimental.**
    [[milestone-a-extended-validation-complete-2026-05-26]] shows
    Milestone A Option (a) silicon survives 30-min Lorenz +
    IEC LOAD + 18h uptime **in passthrough**. Passthrough already
    delivers SuperCPU's stated 20 MHz value (clk_cpu=32 MHz × 1x
    IPC ≈ 20 MHz effective vs vanilla 6510 at 1 MHz). MCP is a
    nice-to-have, not a must-have.

(a) is the most software-transparent fix. (c) is the cheapest path
to ship. User-level decision.

## 3. Confirmed orthogonalities (revised wording)

The mb-probe-003 wedge is NOT caused by:
- Bridge FSM / dwell / handshake ([[mb-probe-002-bridge-falsified-2026-05-26]])
- Bridge transaction count (43k+ delivered during wedge)
- CIA1 Timer A counter (TA varies 391 unique values)
- CIA1 Timer A reload latch (TL stable $4025)
- CIA1 ICR latch hardware (toggles on $DC0D reads)
- CIA1 IRQ mask (IM:01 stable)
- $DC01 bus mux routing (Codex static review found clean path)
- $D012 raster-wait loop (no such code at $EAB1+)
- SCNKEY internals (SCNKEY exits cleanly — appears dominant in
  PC traces only because BASIC GETIN polls it)

The wedge IS:
- A symptom of LOAD failing (drive doesn't respond to IEC LISTEN)
- Sometimes accompanied by BASIC error-print stalling mid-message
- Likely upstream-caused by CIA2 PRA writes being lost under MCP

## 4. Methodology lessons (added this turn)

1. **Always look at the SCREEN, not just UART.** PC-bouncing in
   $EAxx could be a tight loop OR could be normal SCNKEY polling
   from BASIC GETIN; only the screen disambiguates.
2. **Disassemble the actual ROM bytes before claiming what code
   does.** The earlier handoff said "$EAB1+ is raster-wait" with
   no cite; 5 min with the .bin file would have caught it.
3. **Compare WEDGED vs HEALTHY runs on the same build.** All 3
   mb-probe-003 runs showed DEVICE NOT PRESENT. If runs 1+3 are
   "no wedge" but BOTH fail the actual goal (LOAD), the upstream
   failure is what matters, not the wedge stochasticity.
4. **CIA1-focused probes can't reveal CIA2 bugs.** Every
   milestone-B probe so far has been CIA1-internal or
   bridge-internal. CIA2 IEC was never probed despite v8/v13g
   memory pointing at exactly that.

## 5. Firmware-revival attempt (added 2026-05-26 evening)

User asked: "Aren't we doing some patching of the ROM with some
SuperCPU stuff at runtime? Isn't that our firmware?" — this prompted
investigating whether `scpu64.mif` (917 KB, byte-identical to VICE)
ever actually executes on our build. Probe (`tools/dump_vectors_test`)
dumped KERNAL vectors $0300-$0333 and bytes at $801A/$8020/$8000:

- **T65 mode**: stock C64 vectors ($F4A5 ILOAD, $F157 IBASIN, etc.),
  $801A-$8054 = zeros. Expected.
- **SCPU mode**: identical to T65. $801A-$8054 = zeros. → **the
  CMD kickstart never installed handlers**.

Root cause: `scpu_bootmap` was being driven to '0' at reset
(fpga64_sid_iec.vhd:2292), so the bank-$00 $E000+ EPROM overlay
never activated. Without overlay, the RESET vector at $FFFC reads
stock C64 KERNAL ($FCE2 = standard reset), and the CMD chain
$FCE2 → $FC90 → JML $F8:$00FC → JML $F8:$80C1 (kickstart entry)
was never executed.

Memory: [[kickstart-never-runs-confirmed-2026-05-26]].

### 5.1 v346 attempt

Two-line change to enable kickstart at reset:
- Line 2292: `scpu_bootmap <= '0'` → `'1'` at reset
- Lines 2262-2263: outer cpuDi mux carve-out: native-mode bank $F8
  reads route to `cpuDi_raw` (EPROM via buslogic) when bootmap=0,
  so the kickstart can continue reading EPROM after it clears
  bootmap at $F8:$80F7.

Build: md5 `6c854d98`, 65% ALMs, 11:57 Quartus.

Result on hardware:
- Kickstart progresses past STA $D07E (UART captures PCs at
  $F8:$80DA, $F8:$80F1)
- JSL at $F8:$810E enters subroutine at $F8:$8148 (SIMM-detection
  scan) and reaches internal PC $F8:$8174
- **Crashes inside the SIMM scan** — never returns via $F8:$8203
  RTL nor reaches $F8:$8147 RTL → $00:$FCE2 (KERNAL boot)
- CPU ends up stuck in $00:$0000-$0002 BRK runaway + $00:$FF48-$FF58
  ack-stub loop
- Screen stays BLACK in all of t=4s, 8s, 15s, 30s, 60s — BASIC
  never reaches READY

Memory: [[v346-kickstart-partial-2026-05-26]] (updated with 2nd
session verification).

### 5.2 The deeper blocker

The SIMM-scan loop at $F8:$81A9-$81F0 does inverted-pattern test
writes/reads against bank $F6:xxxx via `LDA [$02]` / `STA [$02]`
long-indirect. Our outer cpuDi mux routes bank $F6/$F7 reads to
`ramDin` (SuperRAM SDRAM), and `cs_ram` fires via
`scpu_long_access`. On paper this should work. Empirically the
scan doesn't terminate cleanly — likely because the SDRAM
read-after-write at bank $F6/$F7 returns stale or wrong data
under the specific access pattern used by the scan.

Two compounding issues need investigation:
1. `scpu_sdram_addr` mapping for bank $F6/$F7 (c64.sv:1112).
   `{1'b1, supercpu_bank, c64_addr}` — does this collide with
   anything? Bank $F6 → SDRAM offset $01F60000 = 28.6 MB into a
   32 MB SDRAM. Should be safe but worth verifying.
2. `cs_ram` routing for bank $F6/$F7 in native mode. The
   `scpu_long_access` predicate (buslogic line 551) should fire
   for any non-$00 bank in SCPU mode, but specific timing of
   the read-after-write windows under the SIMM scan may need
   trace-level inspection.

### 5.3 v346 reverted at end of session

- v346 RTL changes reverted (`git checkout fpga64_sid_iec.vhd`)
- MiSTer restored to mb-probe-003 RBF (md5 `ef01bea6`) — boots to
  READY, confirmed by screenshot
- v346 build artifact kept as `C64.rbf` in repo root for future
  diff work (not committed)

### 5.4 Revised options for next session

Options (a)/(b)/(c) from §2.4 still apply, with the following
update to (a):

(a) **Auto-throttle on $DD00 access (RTL state machine)** — still
    the best software-transparent fix. ~1-2 builds. Does NOT
    require firmware revival.

(a') **Full firmware revival (continue v346 path)** — now confirmed
    to need bank-$F6/$F7 SDRAM read-after-write debugging. Many
    builds. Adds full CMD ecosystem when done (IEC throttle, JiffyDOS,
    fast loaders) but is multi-day work.

(b) **POKE $D072,0 launcher wrap** — works today, no build needed,
    user discipline required.

(c) **Ship passthrough** — `ef01bea6` is silicon-validated; 18h
    uptime; passes Lorenz + IEC LOAD in passthrough. Drop MCP turbo
    for v1.0.

Recommendation: try (a) before (a'). If the auto-throttle FSM works,
ship it. If not, fall back to (c) for v1.0 and revisit firmware
revival for v1.1.
