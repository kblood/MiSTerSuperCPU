# Session handoff — 2026-05-26 (late night): v347 Phase 2 SHIPPED — BASIC READY via SCPU EPROM

## 0. TL;DR

Phase 2 of the v346 firmware-revival plan landed in 2 Quartus builds.
The C64 now boots through the CMD SuperCPU EPROM kickstart all the way
to **BASIC V2 / 64K RAM SYSTEM / 38911 BASIC BYTES FREE / READY.**
Source change: 3 RTL edits in `C64_MiSTer/rtl/fpga64_sid_iec.vhd` only.
No new state, no register changes, no buslogic edits.

- Final build: md5 `cfcbf61779c2`, 12:23, 65% ALMs (27,090 / 41,910)
- Commit: `b95b4fe`
- Branch: `milestone-b-cdc-rewrite`
- Boot evidence: `tools/v347b_boot.png` (also sent to user as proactive)
- MiSTer state at session end: `/media/fat/_Test/C64.rbf` =
  v347 RBF (md5 `cfcbf61779c2`), idling at READY.

## 1. What landed (the three edits)

`C64_MiSTer/rtl/fpga64_sid_iec.vhd`:

### 1.1 `scpu_bootmap <= '1'` at reset (line 2317)

Was `'0'` since v345g (2026-05-15). Restores the bootmap=1 startup
that exposes the EPROM at $00:$E000-$FFFF and bank $F8-$FF.
Kickstart's natural STA $D07E at $F8:$80F7 clears bootmap when ready.

### 1.2 cpuDi mux widen carve-out (lines 2286-2288)

Added `and not (emu_mode_816_i = '0' and addr_hi_816 = x"F8")` to
the v345e ramDin gate. Routes native-mode bank-$F8 reads to buslogic
(= scpuRomData) regardless of bootmap. Needed so the kickstart
continuation $80FA-$8146 keeps fetching EPROM after STA $D07E.

### 1.3 NEW v347 SIMM-detect bypass (lines 2277-2289, above the ramDin clause)

```vhdl
x"6B" when (supercpu_en = '1' and addr_hi_816 = x"F8"
            and (cpuAddr = x"8147" or cpuAddr = x"8148")
            and cpuWe = '0') else
```

Synthesises $6B (RTL) at **both** $F8:$8147 and $F8:$8148.

- $8148: sole JSL call site is from $F8:$810E (verified via
  `python tools/disasm_kickstart.py | grep 8148`). Synthesised RTL
  pops the 3-byte return, PC=$F8:$8112, kickstart continues through
  $8112-$8147 and exits to $00:$FCE2 KERNAL boot in emu mode.
- $8147: genuine EPROM byte IS $6B (the kickstart's final RTL). But
  the byte must be served in EMU MODE because XCE at $8146 switches
  modes BEFORE the $8147 opcode fetch. Both the mux carve-outs and
  buslogic line 339's `(native_mode='1' or scpu_bootmap='1')` gate
  fail for `(emu_mode AND bootmap='0' AND bank=$F8)`, so the fetch
  would return ramDin = uninit SDRAM = $00 = BRK runaway (this was
  build #1's FAIL MODE A). Synthesising $6B here matches the
  genuine value, so the patch is non-spoofing at $8147.

## 2. What got tried and what worked

### Build #1 (md5 43b15925, 13:18) — FAIL MODE A

Just bootmap='1' + v346 widen + bypass at $F8:$8148. UART evidence
showed kickstart reached $F8:$8147 (N register frozen there, =
last-fetch in bank /= $00), then PC=$00:$0000-$0002 + $00:$FF48-$FF58
ack stub loop with P:$34 (B-flag set = BRK pushed). Classic BRK
runaway via JMP ($0316) → $0000.

Root cause: XCE in native mode at $8146 switches to emu BEFORE the
$8147 fetch. Buslogic line 339 only serves EPROM for bank>=$F8 when
`(native_mode='1' or scpu_bootmap='1')`. At that moment, both are
false, so $8147 returned SDRAM = $00 = BRK opcode.

### Build #2 (md5 cfcbf617, 12:23) — PASS

Extended the bypass clause to cover $8147 too. READY visible at
t=5s. UART idle confirms textbook clean boot:
- PC bouncing $E5CD-$E5D3 (KERNAL keyboard polling loop)
- J-ring all $E5D1 (kernel main)
- M-ring all $EA31 (default IRQ handler)
- N=$F88147 (last bank-$F8 fetch was the bypass exit — never revisited)
- IF (CIA1 falling-edge counter) incrementing smoothly
- IM:01 CR:01 — CIA1 Timer A IRQ enabled, normal

## 3. What this does NOT achieve

The bypass dodges the natural SIMM scan entirely. The kickstart's
later steps that would have installed the CMD library handlers at
$00:$801A-$8054 do not run. After Phase 2:

- ✅ BASIC READY at boot
- ✅ Vanilla 6510 software runs
- ✅ Doom/Wolf3D should still work (scpu_sdram_addr untouched)
- ❌ MCP+LOAD still wedges (no IEC throttle from CMD)
- ❌ JiffyDOS not active
- ❌ Fast loaders not hooked
- ❌ $0300-$0333 vectors not hooked to CMD handlers

## 4. Recommended next steps

### Cheap validation (no builds)

1. **Lorenz CPU test suite** under v347 — `python tools/lorenz_run.py
   scpu --mins 30`. Confirms no CPU-class regression.
2. **Doom smoke test** — load doom.reu via MGL, launch via the
   POKE $C000+SYS sequence in CLAUDE.md. Confirms scpu_sdram_addr
   path unchanged. The widened native-mode bank-$F8 carve-out could
   in principle affect Doom, but Doom's recompiler emits bank-$FF
   JMLs (693 of them), not bank-$F8.
3. **Vanilla BASIC + cartridges** — sanity-check non-SCPU workloads.

### Phase 3 (deferred, optional)

Implement Codex's "Fourth Option" from
`tools/v346_boot_trace/codex_v346_falsification.txt` point 5: a
narrow SIMM-detect alias mode that mirrors $F6/$F7:xxxx writes so
$02/$03:xxxx reads observe them, gated on a `simm_detect_active`
signal (set on JML to $F8:$80C1 kickstart entry, cleared on
$D07E write). Lets the natural SIMM scan complete, which then
installs the CMD library handlers naturally. ~50-line RTL change
vs the 4-line Phase 2 bypass. Would address MCP+LOAD wedge as a
side effect by restoring the CMD IEC throttle.

### MCP+LOAD (separate, longer-running)

The irq_n-stuck mechanism from
[[mb-probe-003-irq-n-stuck-confirmed-2026-05-26]] is downstream of
"stock KERNAL has no CMD throttle" — Phase 3 firmware revival
would fix it as a natural consequence. Without Phase 3, MCP+LOAD
needs the milestone-b workaround path (RTL auto-throttle on $DD00).

## 5. Working tree at end of this session

- Source: clean. v347 changes committed as `b95b4fe`.
- Boot screenshots (`tools/v347_boot.png` from FAIL #1,
  `tools/v347_boot_t8s.png` second-frame static, `tools/v347b_boot.png`
  from READY): **NOT committed**. Worth committing as evidence if
  next session deems them useful, or delete.
- Build logs (`build_v347.log`, `build_v347b.log`): NOT committed,
  per project convention.
- MiSTer: `/media/fat/_Test/C64.rbf` = v347 (cfcbf617), idle at READY.
  Lockfile NOT held; cooperative use OK.
- Memory: new entry `project_v347_phase2_shipped.md` indexed at top
  of MEMORY.md.

## 6. References

- Commit `b95b4fe` — the v347 RTL change
- `project_v347_phase2_shipped.md` (memory) — full Phase 2 doc
- `project_v346_phase1_3bug_stack.md` (memory) — Phase 1 analysis
- `tools/v346_boot_trace/codex_v346_falsification.txt` — Codex's
  ranked falsification + Fourth Option proposal
- `docs/SIMM_DETECT_ANALYSIS.md` — pre-existing technical analysis
  of the kickstart's SIMM scan
- `tools/scpu64.bin` — raw EPROM image
- `tools/disasm_kickstart.py` — disassembler for the EPROM
