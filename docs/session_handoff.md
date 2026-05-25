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

### 2.4 Strategic pivot: ship passthrough, defer MCP

[[milestone-a-extended-validation-complete-2026-05-26]] shows
Milestone A Option (a) silicon survives 30-min Lorenz scpu +
IEC LOAD + 18h uptime **in passthrough mode**. The MCP gain
is purely speed (clk_cpu 32 → 64 MHz). Per CLAUDE.md,
SuperCPU's value proposition is 20 MHz effective, which we
already hit in passthrough since `clk_cpu=32` MHz with ~3x
IPC vs vanilla 6510 already exceeds 20 MHz equivalent.

User-level decision: is MCP revival worth more debug cycles, or
ship the working passthrough baseline?

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
