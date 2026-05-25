# Session handoff — 2026-05-26 (late evening): v346 Phase 1 complete

## 0. TL;DR

Phase 1 of v346 firmware-revival debugging completed off-device (no
builds burned). Three independent bugs identified and confirmed by
source review + a Codex falsification consult. **The minimal bypass
to reach BASIC READY is a single synthesised byte** (`$6B` = RTL) at
`$F8:$8148`. Implementation is one VHDL clause in the outer cpuDi mux;
no new state machine, no register additions, no risk to existing
behaviour outside the SIMM-detect window.

Next session = Phase 2: implement, build, deploy, verify READY at
t=4s.

## 1. Where we are

### Phase 1 was: cheap-first probes (no Quartus builds)

Per the plan from earlier this session (see scrollback if needed),
Phase 1 was four sub-tasks:
- 1.1 Verify hypothesis in source ✅
- 1.2 Fix `disasm_kickstart.py` long-indirect opcodes ✅
- 1.3 VICE differential ❌ (deleted — source proof was unambiguous)
- 1.4 Codex falsification consult ✅

All findings written to memory: `project_v346_phase1_3bug_stack.md`.
Codex raw output archived at `tools/v346_boot_trace/codex_v346_falsification.txt`.

### What we now know

The v346 wedge is caused by THREE STACKED BUGS, not just one:

**Bug #1 — bank-incorporation in scpu_sdram_addr**
- File: `C64_MiSTer/c64.sv:1112-1116`
- `scpu_sdram_addr = {1'b1, supercpu_bank, c64_addr}` for all non-bank-$00
  SCPU accesses. This is the **music_num=-9 fix** from 2026-04 and must
  not be reverted casually.
- Effect: `$F6:$0000` and `$02:$0000` are DISTINCT SDRAM cells. The
  kickstart's main alias loop at `$F8:$81A9-$81D5` depends on those
  being the SAME cell (so a write to `$F6:$0000` is visible via
  `$02:$XXXX` reads, producing the BNE → exit).
- Without aliasing, the loop iterates ~65 KB. When `$04` wraps `$FF→$00`,
  the next `STA [$02]` writes to bank-$00 zero page (= 6510 I/O port at
  `$0000-$0001`) → memory map corruption → CPU jumps to garbage → BRK
  runaway → end up in `$00:$0000-$0002 / $00:$FF48-$FF58` ack stub.
- Already documented at `docs/SIMM_DETECT_ANALYSIS.md:165` as a known
  failure mode.

**Bug #2 — outer cpuDi mux narrows EPROM exposure**
- File: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:2262-2263`
- Current clause: `ramDin when (...and not (scpu_bootmap='1' and bank>=$F8))`
- Routes bank-$F8+ reads to buslogic (= EPROM via scpu_rom_en) ONLY
  while `bootmap='1'`. But the kickstart clears bootmap at `$F8:$80F7`
  (`STA $D07E` with `$00`), BEFORE entering the SIMM detect at
  `$F8:$810E`.
- v346's carve-out added `(emu_mode_816_i='0' and bank=x"F8")` — fixed
  bank $F8 but NOT $F6/$F7. The kickstart's `$F8:$8205` size-test
  subroutine reads `[$02]=$F6:$0800` and `$F60000`; both get routed to
  uninit SDRAM, not EPROM.
- Codex confirmed this is independent of #1 but does NOT subsume it —
  the size-test at `$8205` returns Z=1 regardless of source (it compares
  the same `$F6:$0800` cell against itself), so kickstart still reaches
  `$81A9` and wedges in #1.

**Bug #3 — $D27D / $D27F hardcoded**
- File: `C64_MiSTer/rtl/fpga64_sid_iec.vhd:1868-1875`
- `$D27D` returns `$02`, `$D27F` returns `$F6` — read-only constants.
  No write logic. The kickstart's `STZ $D27D` and `STZ $D27F` at
  `$F8:$81EB-$81F0` are completely ineffective.
- This bug is actually CONVENIENT for the bypass design (see §2).

### The kickstart continuation past the bypass

Critical for §2's design — disassembled `$F8:$8112-$8147` (run
`python tools/disasm_kickstart.py` after applying the $C7/$47/$E6/...
opcode fixes from this session):

```
$8112: LDA $D27F            ; loads hardcoded $F6
$8115: SEC; SBC $D27D        ; $F6 - $02 = $F4 (non-zero)
$8119: BEQ $813D             ; NOT TAKEN (A=$F4 ≠ 0)
$811B: CLC; ADC #$0F; ROR; LSR; LSR; LSR
$8122-$812C: arithmetic to convert size to ASCII digit
$812E: STA $01:$E49C         ; patches "256K" digit into KERNAL shadow
$8132: TXA; STA $01:$E49B    ;        (writes to SuperRAM, never read
$8137: LDA #$4D ('M')        ;         by our KERNAL boot path)
$8139: STA $01:$E49D
$813D: PHB
$813E: REP #$20              ; 16-bit A
$8140: LDA $FFFC             ; reads C64 KERNAL RESET vector = $FCE2
$8143: DEC                   ; → $FCE1
$8144: PHA                   ; pushes $FCE1 (16-bit)
$8145: SEC; XCE              ; E goes 0→1 = emu mode
$8147: RTL                   ; → $00:$FCE2 in emu mode → KERNAL boot
```

So the **only** dependencies of `$8112+` on the SIMM scan are the
hardcoded `$D27D=$02` / `$D27F=$F6` reads. Those send execution down
the size-display path which writes to SuperRAM bank `$01` (harmless in
our impl because we don't shadow KERNAL ROM from bank `$01`). Then RTL
to KERNAL.

## 2. Phase 2 — implementation plan

### The change (1 RTL clause)

`C64_MiSTer/rtl/fpga64_sid_iec.vhd`, in the outer cpuDi mux at line
~2240 (immediately ABOVE the existing v345e bank-$F8+ clause at
2262-2263):

```vhdl
-- v347: SIMM-detect bypass. Single-byte synthesis at $F8:$8148 returns
-- RTL ($6B). Kickstart's JSL at $F8:$810E pushes return $F8:$8111;
-- our RTL pops it; PC = $F8:$8112; kickstart continuation reads
-- hardcoded $D27D=$02 / $D27F=$F6 (line 1870-1875), takes the benign
-- size-display patch path, RTLs to $00:$FCE2 → KERNAL boot → READY.
-- Required because:
--   1. scpu_sdram_addr (c64.sv:1115) makes $F6:0000 ≠ $02:0000,
--      breaking kickstart alias-loop exit at $F8:$81A9-$81D5.
--   2. outer cpuDi mux below narrows EPROM to (bootmap=1 AND bank>=$F8),
--      but kickstart clears bootmap at $80F7 before SIMM detect.
-- See project_v346_phase1_3bug_stack.md for full analysis.
x"6B" when (supercpu_en = '1' and addr_hi_816 = x"F8"
            and cpuAddr = x"8148" and cpuWe = '0') else
```

That's it. No new register. No new signal. No state machine. No
priority/timing concerns — `cpuAddr=x"8148"` is precise enough that
only the SIMM-detect entry triggers it.

### Required source changes

1. **Re-apply v346 RTL** (currently reverted on disk):
   - Line 2292: `scpu_bootmap <= '0'` → `scpu_bootmap <= '1'` at reset
   - Lines 2262-2263: add `or (emu_mode_816_i = '0' and addr_hi_816 = x"F8")`
     to the existing carve-out. This is the original v346 widen-for-native-mode
     carve-out — needed so the kickstart can keep fetching from bank $F8
     after it clears bootmap.

2. **Add the new bypass clause** (above the existing 2262 clause):
   - `x"6B" when (supercpu_en='1' and addr_hi_816=x"F8" and cpuAddr=x"8148" and cpuWe='0') else`

The bypass clause must come ABOVE the v345e/v346 clause so it takes
priority. Quartus evaluates the `when ... else` chain in order, so
this is straightforward.

### Risks (mostly accepted)

- **Anything else JMPing/JSRing to $F8:$8148 directly** (not via JSL
  from `$810E`) would also get the RTL bypass. Cheap defensive check:
  run `python tools/disasm_kickstart.py | grep -E '(JSR|JSL|JML).*8148'`
  to confirm there's only one call site (the doc's flow chart at
  SIMM_DETECT_ANALYSIS.md:64-130 says only one).
- **The SIMM scan was supposed to also set SuperRAM cache config**
  (optimization mode flags `$D074-$D076`). If anything later in the
  kickstart or in CMD library handlers depends on this state, we get a
  silent regression. Test surface: `scpu_speedtest.crt`, SCPU BASIC
  POKEs to `$D072/$D07A` etc.
- **Bug #3 still latent** — if a future workload writes to `$D27D` or
  `$D27F` expecting it to land, it'll silently fail. Phase 3 could
  un-harden these (make them r/w registers), not required for
  kickstart→READY.

### Pass/fail criteria

**PASS**: Screen reaches `BASIC V2 / 64K RAM SYSTEM / READY.` at t=4s
or t=8s. UART shows PC bouncing through `$00:$E000-$00:$EFFF` (KERNAL
+ BASIC idle loops), `IF:`/`C1:` ticking smoothly.

**FAIL mode A** — black screen, same v346 wedge profile (PC stuck at
`$00:$0000-$0002` BRK loop + `$00:$FF48` ack stub):
- The bypass clause didn't fire. Check `addr_hi_816` vs `cpuAddr` vs
  `supercpu_bank` (different signals at different lexical points in
  fpga64_sid_iec.vhd — make sure we used `addr_hi_816` (the cpu-side
  signal) and `cpuAddr` (cpu-side 16-bit).

**FAIL mode B** — black screen, NEW wedge profile (PC stuck at
`$F8:$8112` or further down in the size-display patch):
- The RTL fired but landed somewhere wrong. Check stack balance: JSL
  pushed PBR, PCH, PCL of return = $F8:$8111. RTL pops them in
  REVERSE: PCL=$11, PCH=$81, PBR=$F8 → PC=$F8:$8112 after the +1
  increment. If PC ended at `$8111` instead, that's a 65C816 RTL
  semantic mismatch — investigate the P65C816 core's RTL handling.

**FAIL mode C** — READY appears but immediately corrupts:
- Stack leak from the bypass (4 bytes per analysis) somehow not
  recovered by KERNAL's `LDX #$FF; TXS` at `$FCE6`. Highly unlikely
  but possible if our P65C816 core's SP semantics differ in emu mode.

### During the Quartus build (parallel work)

The build is ~30-40 min wall, 0% interactive load on Claude. Use the
window for:

1. **Bug #1 fix design** — if Phase 2 lands READY but we want Phase 3
   eventually, design Codex's "Fourth Option" (narrow SIMM-detect
   alias mode mirroring $F6/$F7 writes to $02/$03 reads while
   `simm_detect_active='1'`). See `tools/v346_boot_trace/codex_v346_falsification.txt`
   for Codex's framing.

2. **Disasm of $F8:$80C1-$80F0** (kickstart entry, pre-SIMM-detect) to
   understand exactly what state is set up before `$810E`. Useful for
   Phase 3 (CMD library install).

3. **Re-read `docs/SIMM_DETECT_ANALYSIS.md`** with the three-bug
   context in mind. The doc was written before Bug #2 and Bug #3
   existed — parts of it are stale (e.g., line 73-79 assumes bank
   $F6 reads return EPROM; current source proves they don't post-
   bootmap-clear).

### Give-up criterion for Phase 2

If 2 builds fail with the same mode, escalate to Phase 3 (real fix
for Bug #1 via Codex's Fourth Option). If failure modes drift each
build, the bypass clause's placement in the mux is wrong — read more
fpga64_sid_iec.vhd before a 3rd build.

## 3. What Phase 2 does NOT achieve

The bypass gets us to BASIC READY, but the CMD ecosystem (IEC throttle,
JiffyDOS hooks, fast loaders, CMD library at `$00:$801A-$8054`) is NOT
installed. The kickstart's MVNs at `$80D7/$80E3/$80EF` did copy bytes
to bank `$01` shadow, but the actual install of handlers into bank
`$00` zero-page vectors `$0300-$0333` and code at `$00:$801A-$8054`
happens later (probably inside the SIMM-detect subroutine, or
dependent on its exit conditions).

So after Phase 2:
- ✅ BASIC READY at t=4s
- ✅ Vanilla 6510 software runs (T65-compatible)
- ✅ Doom/Wolf3D should still work (we don't touch scpu_sdram_addr)
- ❌ MCP+LOAD still wedges (no IEC throttle from CMD)
- ❌ JiffyDOS not active
- ❌ Fast loaders not hooked

Phase 3 would add these back. The cleanest design (per Codex) is to
implement Bug #1's "Fourth Option" so the SIMM scan completes normally,
which then runs the rest of the kickstart's setup naturally. That's a
~50-line RTL change vs the 1-line Phase 2 bypass.

## 4. Working tree at end of this session

### Source state

- `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — RTL reverted to silicon-validated
  baseline. v346 changes NOT applied. Phase 2 implementation needs to
  re-apply v346 + add the new bypass clause.
- `C64_MiSTer/rtl/fpga64_buslogic.vhd` — unchanged.
- `C64_MiSTer/c64.sv` — unchanged.
- All Phase 1 artifacts committed to git as `636c24c`:
  - `tools/test_cart/gen_dump_vectors.py`
  - `tools/dump_vectors_test.py` (and the test output dir)
  - `tools/v346_boot_trace/` (5 boot screenshots + UART log)
  - `tools/v346_boot_trace/codex_v346_falsification.txt` (added late, not in 636c24c — see below)
  - `tools/v346_boot_trace/restored_mb_probe_003.png` (READY shot)
  - `docs/session_handoff.md` (this file, latest update)
- `tools/disasm_kickstart.py` — modified to add long-indirect ($C7/$47/etc)
  and zp RMW ($06/$E6/$C6/$D6/$F6/$16/$26/$36/$66/$76/$46/$56) opcodes.
  NOT yet committed.

### Uncommitted vs committed

`tools/v346_boot_trace/codex_v346_falsification.txt` (Codex output)
and the disasm_kickstart.py opcode additions are uncommitted at session
end. Stage them at Phase 2 start (`git add` listed files) before the
Phase 2 RTL changes go in.

### MiSTer state

- `192.168.50.130 /media/fat/_Test/C64.rbf` = mb-probe-003 RBF
  (md5 `ef01bea65d493c4177a28ad46a77cf55`). Boots to BASIC READY
  cleanly. Suitable for cooperative use by next session.
- Lock file `/tmp/mister_session.lock` released at end of this session.

### Memory updates

- New: `project_v346_phase1_3bug_stack.md` — full Phase 1 analysis,
  three-bug taxonomy, minimal bypass design.
- Updated: `MEMORY.md` top entry — index pointer to phase 1 doc.
- Existing: `project_v346_kickstart_partial.md` — still valid,
  REFINED by the new entry.
- Existing: `project_kickstart_never_runs_confirmed.md` — still valid,
  upstream context.

## 5. Phase 2 quickstart for next session

```bash
# 0. Confirm clean state
cd C:/LLM/C64/MiSTerSuperCPU
git status                              # working tree clean except disasm + codex_out
python tools/mister_debug.py status     # CORENAME, ownership

# 1. Apply v346 + new bypass clause
# Edit C64_MiSTer/rtl/fpga64_sid_iec.vhd:
#   - line 2292: scpu_bootmap <= '0' → scpu_bootmap <= '1'
#   - lines 2262-2263: add ' or (emu_mode_816_i = '0' and addr_hi_816 = x"F8")'
#   - above line 2262: insert the new bypass clause:
#       x"6B" when (supercpu_en = '1' and addr_hi_816 = x"F8"
#                   and cpuAddr = x"8148" and cpuWe = '0') else

# 2. Stage everything
git add C64_MiSTer/rtl/fpga64_sid_iec.vhd \
        tools/disasm_kickstart.py \
        tools/v346_boot_trace/codex_v346_falsification.txt

# 3. Build (~30-40 min)
./build_c64.ps1

# 4. Deploy and verify
python tools/mister_debug.py deploy C64.rbf
# Wait 4s
python tools/mister_debug.py screen tools/v347_boot.png
# Inspect: should show BASIC V2 / 64K RAM SYSTEM / READY.
```

## 6. References

- `tools/v346_boot_trace/codex_v346_falsification.txt` — Codex's ranked
  falsification of H1/H2 + Fourth Option proposal
- `docs/SIMM_DETECT_ANALYSIS.md` — pre-existing technical analysis;
  line 165 lists bank-incorporation as known failure
- `tools/scpu64.bin` — raw EPROM image, use with `tools/disasm_kickstart.py`
- Memory: `project_v346_phase1_3bug_stack.md` (this session's Phase 1
  doc, indexed in MEMORY.md)
