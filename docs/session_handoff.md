# SCPU full implementation plan — Phases 1-8 LANDED 2026-05-11

## Bottom line

All 8 phases of `docs/scpu_full_implementation_plan.md` are now committed
on `vanilla-cpu-swap` (HEAD = `b599319`). Phase 1, 3, and 6 added RTL;
Phases 2, 4, 5, 7, 8 were audited as already-implemented or
architecturally-incompatible and committed as doc-only annotations.

The deployable artefact is the Phase 6 RBF at
`C64_MiSTer/output_files/C64.rbf` (md5 `a3b1adb9c867aaa9aa277c563d9fd090`,
3,831,204 bytes). It includes all Phase 1+3+6 RTL. The Phase 4/5/7/8
doc commits added no RTL so the same RBF applies.

## Build metrics (Phase 6)

- ALM: 26,968 / 41,910 (64%)
- M10K: 403 / 553 (73%)
- clk32 setup slack: -4.698 ns (unchanged from pre-Phase-1 baseline)
- Total registers: 30,681
- RBF md5: a3b1adb9c867aaa9aa277c563d9fd090

Quartus 17.0.2 SJ Lite. `build_c64.ps1` syntax check (analysis &
elaboration) PASSED with 0 errors, 77 warnings.

## Per-phase status

| # | Phase                            | Status   | Mechanism on this branch                          |
|---|----------------------------------|----------|---------------------------------------------------|
| 1 | IOF falling-edge fix             | RTL ✓    | `iof_fall_pulse_r` + latched cpu_we/addr/dout      |
| 2 | I/O cycle stretching             | doc      | CPUC-only arbitration > VICE's 2-3 cycle stretch   |
| 3 | EPROM-driven boot + RAM kernel   | RTL ✓    | bootmap overlay + scpu_native_vec writable array   |
| 4 | Bank $01 SRAM shadow             | doc      | Already ROM-shadows $A000-$BFFF/$D000-$DFFF/$E000-$FFFF |
| 5 | WriteSmart + write buffer        | doc      | CPUC arbitration is functionally a 1-byte buffer   |
| 6 | $D0BC R/W + $D0BE/$D0BF          | RTL ✓    | `scpu_dos_ext_mode` register                       |
| 7 | $D078 unrepurpose + bootmap ROM  | doc      | $D078 has no cache_flush; bootmap dprom exists     |
| 8 | 1MHz badline emulation           | doc      | `rdy => baLoc` already stalls CPU on VIC badlines  |

## Commit chain (push'd to origin/vanilla-cpu-swap)

```
b599319 Phase 5: WriteSmart + write buffer — architectural gap doc, no RTL
58673f5 Phase 8: 1MHz badline emulation in turbo — already implemented via rdy=>baLoc
8d90f47 Phase 4: Bank $01 SRAM shadow — audit shows complete on this branch
ccca7b7 Phase 7: $D078 unrepurpose + bootmap ROM — doc-only on vanilla-cpu-swap
aee2577 Phase 6: $D0BC R/W + $D0BE/$D0BF DOS extension register
7b92166 Phase 3: EPROM-driven boot intercept + writable native vectors
05e622d Phase 2: I/O cycle stretching — already implicit, document why
2cdf04a Phase 1: port IOF falling-edge fix from master
bb1c8e2 docs: full SCPU implementation plan — 8 phases targeting VICE/CMD spec
```

## Build cycle gotcha

`build_c64.ps1` has a try/finally QSF restore race with `quartus_fit`
when the fitter elapsed time exceeds ~9 minutes. Symptom: error
125085 ("Settings File changed outside the Quartus Prime software")
during placement, then `Current module quartus_fit ended
unexpectedly`. Fitter completes successfully but `quartus_asm` is
never invoked so no new RBF is produced.

Workaround that produced the Phase 6 RBF:

```bash
wsl bash --noprofile --norc -c "cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer \
  && /home/caldor/intelFPGA_lite/17.0/quartus/bin/quartus_asm \
     --read_settings_files=on --write_settings_files=off C64 -c C64"
```

Long-term fix: widen the `finally Restore-DebugMacros` in
`build_c64.ps1` to wait for `quartus_asm` to finish before restoring
the QSF, OR copy the QSF aside and restore from copy without rewriting
the original file mid-flow.

## Pending: hardware gate

MiSTer at 192.168.50.130 was busy with `JamesPond3-CD32MVP` at session
end (`/tmp/CORENAME` mtime 19:07). Per the cooperation protocol I
deferred hardware deploy. When MiSTer frees:

```bash
python tools/mister_debug.py deploy C64_MiSTer/output_files/C64.rbf
# expected md5 on /media/fat/_Test/C64.rbf:
#   a3b1adb9c867aaa9aa277c563d9fd090
```

Then run the v298 Doom regression suite:

```bash
python tools/doom_v298_transition_zoom.py
python tools/doom_v298_wedge_capture.py
```

Pass criteria:
- No $2B:$2292 SP-leak wedge (v298/v299 baseline failure mode)
- No $0F BRK-march to $24Dxx (v298 alternate failure mode)
- Title splash renders + at least one playable frame captured

If both wedges persist after Phase 1+3+6, the bug is in the data
layer (Phase 5 WriteSmart / REU→SuperRAM transfer corruption) and
needs a different investigation path than the 8-phase plan covers.

## Cocotb status

Cocotb is not installed in this WSL session — Layer A diff harness
cannot be re-run from this shell. Prior MATCH proofs
(test-doom-bank20, test-doom-gameplay, test-doom-loader-body) remain
valid for the P65C816 CPU microcode. Phase 1+3+6 RTL changes touch
reu.v wiring + bank-$00 cpuDi mux + $D0BC register — all OUTSIDE
the cocotb CPU-only DUT scope. So no cocotb regression risk from
these phases; verification must happen on hardware.

## Memory protocol

After hardware gate passes, write a new project memory entry summarising
the v300 result and supersede the v294-v299 wedge entries
(`project_doom_v29[3-9]_*.md`).
