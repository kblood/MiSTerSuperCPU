# Session handoff — 2026-05-27: Bug 3 + Problem C shipped, IEC handshake remains

## 0. TL;DR

- **SHIP BUILD: Problem C (`20c9e10`, RBF md5 `0c253fb4`).** Boots to BASIC READY.
- **Two commits this session:**
  - `bc883d4` — Bug 3: writable SIMM-extent registers $D27C-$D27F (silicon-verified via BASIC PEEK).
  - `20c9e10` — Problem C: per-access CIA2 auto-throttle. Unfreezes CIA1 Timer A during LOAD path.
- **CDC theory is dead** — `clk_cpu === clk_sys` at `c64.sv:349`. The "outer mux dead" symptom was a measurement artifact. See memory `bug3_outer_mux_actually_works_2026-05-26`.
- **LOAD"$",8 still does NOT complete** but for a different reason now: drive 8 never acknowledges LISTEN. CIA2 PA reads stuck at $0F across 125 frames → writes apparently lost despite v13g `cia2_write_safe` widening.

## 1. What Problem C did

`fpga64_sid_iec.vhd:1344-1352, 3172-3195` — added 7-bit counter that reloads to N=64 clk32 on any accepted CPU CIA2 access (`supercpu_en + addr_hi_816=$00 + cs_cia2 + enableCpu_816`), OR'd into `scpu_force_1mhz`. While nonzero, throttles CPU to 1MHz so KERNAL IEC timing loops don't race CIA1.

### Verified effect (LOAD"$",8 on `lorenz_disk1.d64`)

| metric | Bug 3 baseline (014d2bfb) | Problem C (0c253fb4) |
|---|---|---|
| Wedge PC | $00:$E5D5 stuck | $00:$ED50/$EEB0/$EEB3 cycling |
| CIA1 Timer A | TA=$3C7B FROZEN | TA decrementing |
| IRQ counter (IF) | $0CE7 frozen | varies (with I=1 suppressed) |
| IRQ mask (IM) | $00 (TA IRQ off) | $01 (TA IRQ on) |
| Last IRQ taken (M) | F1CA F1CA A483 F157 | EA31 EB48 EA31 EB48 |
| CIA2 PA stable | $07 | $0F |
| LOAD completes? | No | No |

CIA1 is healthy now. The remaining wedge is downstream: CIA2 PA writes don't update the output register, so `iec_atn_o = NOT cia2_pao(3)` never asserts — drive 8 never hears LISTEN.

## 2. Next bug — CIA2 PA write-loss in MCP mode

UART evidence: 125/125 samples show `PA:0F` while CPU loops in KERNAL ED50/EEB0/EEB3. KERNAL writes $30/$28/etc. to $DD00 during LISTEN setup; none latch into `cia2_pao`.

### Suspect

`fpga64_sid_iec.vhd:2797` CIA2 cs_n gate:
```vhdl
cs_n => not (cs_cia2 and (not cpuWe or cia2_write_safe))
```
`cia2_write_safe = vpa_816 or vda_816 or vpa_816_d1 or vda_816_d1` (line 1689, v13g widened window).

CIA latches writes only on `enableCia_p` (CYCLE_CPUF). In MCP mode the vpa/vda window may not align with CYCLE_CPUF for CIA2 writes, even widened.

Memory cross-ref: `mb_probe_003_misdiagnosis_pivot_2026-05-26` — known long-standing IEC write-loss bug in MCP. CIA1 was previously a "v13d narrow gate works for CIA1". CIA2 still vulnerable.

### Investigation handles

1. Add UART probe for `cia2_pao` post-write (capture last 4 PA values written).
2. Check whether `enableCia_p` actually fires while `cia2_write_safe='1' AND cs_cia2='1' AND cpuWe='1'` — could compare via internal counter.
3. Consider gating CIA2 cs_n by a wider window (e.g. latch cs_cia2+cpuWe+cpuDo for N cycles around the request) — more aggressive than vpa/vda widening.
4. Compare passthrough vs MCP — what's different about vpa/vda timing? (passthrough now wedges kickstart per `btest_passthrough_breaks_boot_2026-05-27` so it's not a free A/B.)

## 3. Operator state

- `/tmp/mister_session.lock` rewritten to `agent=claude task=c64-problem-c-validate since=2026-05-27T02:09`.
- `/media/fat/_Test/C64.rbf` = Problem C build (md5 `0c253fb4`).
- `/media/fat/_Computer/` untouched (vanilla rbfs intact).
- Working tree clean.
- HEAD: `20c9e10` on `milestone-b-cdc-rewrite`.

## 4. Pending / deferred

- **MGL `<file type="f">` PRG autoload** — disks mount via MGL but the PRG-file element silently fails. Worked around in this session by using `mtype.py` for keystrokes (after fixing `disk_ready` mask via Empty.d64 mount).
- **Bug 2 (kickstart SIMM-scan natural exit)** — Codex offered a deeper probe (8-byte FL/BK/FW/FR/WA/WB/R2/ST pack). Deferred; only useful if MCP+LOAD revival path is pursued for CMD-DOS firmware. Most likely not load-bearing for the CIA2-write-loss fix.
- **Doom regression** — orthogonal. Last validated on async-cpu-bridge with passthrough=0 (commit pre-milestone-b). Current build needs MCP active for boot; flipping passthrough='1' wedges kickstart. Doom revival is a separate workstream.
