# Session Handoff

## 🟥⚡ iter-22 (2026-06-04): Cache Bug 2 — fill/invalidate race bench reproduces the iter-18 HW signature + a cancel fix, but the fix is HW-FALSIFIED. Reverted, committed `2b4d7ac` (unpushed). Speed lever still parked.

**GOAL: unlock the HW-proven 3x same-line alt-fire (commit `0deb093`), which is
shipped OFF because it needs `CACHE_READ_PATH=true` and that path has an open
SuperRAM read-coherency bug (Bug 2) that crashes Doom.**

**WHAT WAS DONE.** The strongest Bug-2 signal is iter-18's on-silicon divergence
detector residual: `bank $20 $00AE cache=$00 (pre-write empty) vs SDRAM=$4A
(loader-written)` = a loader-write -> fill-read ordering race. Built a new GHDL
bench `sim/cache_coherency_tb/cpu_cache_fill_invalidate_race_tb.vhd` that
reproduces that exact signature off-device (BUG=1) and proves a fix
(`FILL_CANCEL_ON_WRITE`: clear the pending `rp_fill_req` on a matching CPU write
-> re-read misses -> SDRAM path returns $4A; FIX=0). Implemented the cancel in
`fpga64_sid_iec.vhd`.

**RESULT: HW-FALSIFIED** (build `404422c5`, `CACHE_READ_PATH=true` isolation,
alt-fire OFF). Boot clean, but Doom did NOT reach title — wedged at `PC:00D013`
(crashed into I/O space, white screen) and the divergence detector STILL read
`WD=2` at `$20:00AE`, byte-identical to iter-18. The GHDL-proven cancel is a HW
no-op: its window (read-miss -> fast fill-fire, ~4 clk32) does NOT overlap the
loader's write (many loops later) — the fill fires and allocates the stale $00
BEFORE the write arrives, so there is no pending fill to cancel. The unit bench
placed the write INSIDE the pending window = a timing that doesn't occur in
deployed passthrough (same sim/HW mismatch class as FILL_TXMATCH, iter-16).

**STATE NOW.** Reverted `CACHE_READ_PATH=false` (Doom-safe, RBF bit-identical to
shipped). `FILL_CANCEL_ON_WRITE` stays in source, inert (closes a real but rare
race; NOT the Bug-2 cause). MiSTer restored to iter-21 baseline `4671ecfc`, lock
released, boot clean (SCPU64 V0.07). Committed `2b4d7ac`.

**NEXT (GHDL-first, the real lesson).** The `cpu_cache` UNIT bench cannot see the
actual fill-fire-vs-write ordering — every unit-level "fix" (FILL_TXMATCH,
FILL_CANCEL_ON_WRITE) has been a HW no-op because the deployed passthrough timing
differs from the hand-pulsed bench. A faithful SYSTEM-level repro is required
before any further cache-on HW build: extend `c64_reduced_harness` (fpga64 +
sdram_pm + a loader write->read sequence) so the fill FIRE timing, the
invalidate, and the SDRAM read latency are all real. Reproduce the persistent
`cache=$00 vs SDRAM=$4A` there, then fix, then ONE HW build. Do NOT build another
cache-on RBF off a unit-bench-only fix. Alternative levers if Bug 2 stays stuck:
Milestone C demand arbiter @ clk32 (separate path, no cache dependency).

## ✅🎮 iter-21 (2026-06-04): SHIPPED — MVP/MVN emu-mode block-move address bug FIXED, GHDL-PROVEN, HW-VERIFIED, COMMITTED (`e6b3405`, unpushed)

**STATE: DONE. One genuine 65816 functional bug (MVP/MVN $44/$54 block-move
address generation in emulation mode) found + fixed in `AddrGen.vhd`,
GHDL-validated against the full 10000-case SST silicon-trace suite (both modes,
0-fail), ZERO regressions across the 512-opcode sweep. Build GREEN (RBF md5
`4671ecfc`). HW-VERIFIED 2026-06-04 on the freed MiSTer: boot to READY clean +
Lorenz scpu (8min) AND t65 (4min) both regression-clean — continuous progress,
all tests "ok", no wedge. Committed as `e6b3405` on `milestone-b-cdc-rewrite`
(push still gated on user). MiSTer lock released.**

### NEXT SESSION ENTRY POINT
iter-21 is closed. Remaining SST fails are both explicitly deferred (see
backlog below): **$40 RTI** cycle-count (functionally correct, low value) and
**$e1 SBC(dp,X)** (1-in-10000 boundary case, low value × high regression risk —
shared emu dp-wrap path). No other genuine compat bug is currently surfaced by
the SST suite. Next highest-leverage compat lever = a broader/fresh SST or
SuperCPU-library sweep to surface the next real bug, or revisit the parked speed
work (cache read-path coherency / in-816 pipeline). Pick per north-star at
session start.

### What was found & fixed

**The bug (genuine functional, emulation-mode only).** MVN ($54) / MVP ($44)
block moves formed the source (`{srcbank, X}`) and destination (`{DBR, Y}`)
24-bit addresses with the **high byte = stale PCH** instead of `X.H` / `Y.H`
(which are $00 in 8-bit-index mode). The LOW byte was correct and incremented
properly, so the move walked the right offsets in the WRONG 256-byte window and
never touched the intended memory. SST signature: `RAM[8600B6] exp=06 got=00`
(dest never written); observed bus `F3EA67` vs expected `F30067`, `5CEAF3` vs
`5C00F3` — the $EA is PCH leaking into bits 15:8. 49/50 cases failed before the
fix.

**Root cause.** `C64_MiSTer/rtl/65C816/AddrGen.vhd` — the high-byte address mux
handles the block-move direct loads `IND_CTRL="10"` (`X->AA`) / `"11"` (`Y->AA`)
**only in the native `e6502='0'` branch** (lines ~142-145). The emulation `else`
branch ignored `IND_CTRL` entirely and left `NewAAH` = stale `AAH`. Only MVN/MVP
use `IND_CTRL` 10/11, so the fix is fully isolated — no other opcode can change.

**The fix.** Added `IND_CTRL="10"/"11"` → `"0" & X(15:8)` / `"0" & Y(15:8)`
handling to the emulation branch, ahead of the unchanged dp,X/dp,Y page-cross
logic. (`X.H`/`Y.H` are held at 0 in 8-bit-index mode → correct $00 high byte.)

**Bench fix that exposed it.** `sim/p65c816_singlesteptest/p65c816_sst_tb.vhd`:
the cycle-record buffers were sized `0 to 31`; MVP/MVN block moves emit up to
100 bus cycles/case, so the bench asserted "cycle count exceeds buffer (>31)"
and could not test them at all. Enlarged both `cyc_arr_t` and `cyc_obs_arr_t`
to `0 to 127` and the assert to `<=127`. This made $44/$54 testable, which
immediately surfaced the CPU bug above (NOT a test artifact).

### Validation
- **GHDL/SST (silicon oracle):** $54.e/$54.n/$44.e/$44.n all **fail=0 at full
  10000 cases** (skips 0/8/0/6 = normal prelude collisions). Pre-fix: 49/50
  fail.
- **Regression:** full 512-opcode sweep (300 cases/op) = ZERO new fails. Only
  failures are the pre-existing/deferred **$40 RTI** cycle-count (599, functionally
  correct). Everything else 0-fail. Change is block-move-exclusive so this is
  expected.
- **Build:** 0 errors, RBF md5 `4671ecfc`, ALMs 31,530/41,910 (75%). All clock
  domains TNS=0; worst-case setup slack 0.443ns is pll_hdmi (orthogonal); CPU
  domains 3.7-4.2ns, SDRAM 4.48ns — all positive.
- **HW: PENDING** (MiSTer busy with CD32 agent). Note: MVN/MVP are 65816-only
  and NOT in the Lorenz suite, so the HW step is purely a boot+Lorenz regression
  guard (confirm no t65/scpu regression); the fix itself is proven by SST.

### RESUME STEPS (when MiSTer frees — re-check `/tmp/CORENAME` == empty or C64)
1. `python tools/mister_debug.py deploy` (RBF already at `output_files/C64.rbf`;
   archived `builds/...4671ecfc-dirty.rbf`).
2. Boot to READY (SCPU64 V0.07) check.
3. `tools/lorenz_run.py scpu` + `tools/lorenz_run.py t65` — both must stay
   continuous / all-"ok" / no wedge.
4. If clean → commit (build green + HW regression-clean). Files:
   `C64_MiSTer/rtl/65C816/AddrGen.vhd` + `sim/p65c816_singlesteptest/p65c816_sst_tb.vhd`.
   Push still gated on user.

### NEXT compat backlog (GHDL-first, after iter-21 commits)
- **$40 RTI** cycle-count (missing one internal IO cycle; functionally CORRECT,
  PC restored right — low value, risks interrupt latency). Only remaining SST
  fail class besides MVP/MVN (now fixed).
- **$e1 SBC(dp,X)** = 1 edge case (#8668 in 10000). CHARACTERIZED this session:
  direct-page wrap discrepancy in the (dp,X) indirect POINTER fetch. With E=1,
  DL=$00, D=$F400, dp=$B0, X=$4F → pointer-low at $00:F4FF (correct), but our
  core fetches pointer-HIGH with 6502 page-wrap ($F4FF→$F400, pointer=$002F)
  whereas the silicon trace does a full 16-bit increment ($F4FF→$F500,
  pointer=$3E2F). Wrong pointer → wrong operand → wrong result → the reported
  `P exp=30 got=31` (carry) is downstream, NOT a carry-ALU bug. ⚠️ HIGH
  REGRESSION RISK: the emu dp-wrap logic is in `AddrGen.vhd` (the same emu
  `else` branch iter-21 touched, AAHCtrl="110"/DLNoZero path) and is SHARED by
  all dp,X/(dp),Y/[dp] modes — needs a multi-case study of the exact WDC wrap
  rule (textbook "DL=0 wraps within page" disagrees with this SST trace) + full
  512-op regression before changing. Extract single cases with the renumber
  trick: `e1_case8668.txt` generator (C-index must match bench's 0-based
  counter or it asserts "case-index mismatch").
  TRIAGE (this session, GHDL 10000 each): the WHOLE (dp,X) indirect family —
  $01/$21/$41/$61/$81/$a1/$c1 — passes 10000/10000 in emu mode; only $e1 has
  its one boundary case (different per-opcode random corpora, so this is a
  coverage artifact, not e1-specificity — the bug is latent across the family).
  ⇒ the dp addressing path is fundamentally SOLID; this is a rare boundary
  quirk. VERDICT: LOW value (≈no software depends on the DL=0 + dp+X=$FF +
  16-bit-pointer corner) × HIGH risk (shared path, 9999+ passing cases) ⇒
  stay deferred; do NOT rush. If ever fixed: the silicon truth is pointer-HIGH
  uses full 16-bit increment ($F4FF→$F500), NOT 6502 page-wrap ($F4FF→$F400),
  even when DL=0 — contradicts textbook lore; trust the SST trace.
- SST suite remains the highest-leverage off-device compat lever.

### Speed status (unchanged from iter-19)
All cadence/raised-clock >4MHz levers HW-dead; cache read-path parked (coherency);
only remaining speed lever = pipeline inside the P65C816 di->ALU->PC (deep,
multi-session). Same-line 2x alt-fire (3.0x, commit 0deb093) rides the parked cache.
