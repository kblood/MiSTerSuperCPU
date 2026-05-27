# Session handoff — 2026-05-27: CIA2 PA write-loss fixed, CIA1 read race surfaces

## 0. TL;DR

- **SHIP BUILD: v14 (`a0dd60e`, RBF md5 `46c9def9`).** Boots to BASIC READY.
- **Three commits this session (post-Bug 3):**
  - `20c9e10` — Problem C: per-access CIA2 auto-throttle (unfreezes CIA1 Timer A during LOAD path).
  - `617a5b3` — docs: handoff after Problem C.
  - `a0dd60e` — v14: CIA2 write latch+replay (writes now actually land at CIA's phi2_n sample edge).
- **Bug peeled one layer**: PA stuck at $0F → PA now $D7 with ATN OUT asserted. Drive 8 is hearing LISTEN. LOAD"$",8 still does not complete — the new wedge is **SCNKEY de-bounce** at $00:$EAB4-$EACF with IF counter frozen. That's a known **CIA1 read race** documented in memory `mb_probe_003_misdiagnosis_pivot_2026-05-26` ($EAAB LDA $DC01 / CMP $DC01 / BNE).

## 1. What v14 did

`fpga64_sid_iec.vhd:1469-1492, 2800-2860` — added `cia2_wr_pending/fire/rs/do` latch+replay. Captures any cs_cia2+cpuWe+cia2_write_safe attempt, replays at sysCycle=CYCLE_CPUC so cia2_cs_n is held low for the entire CYCLE_CPUD interval (when enableCia_n='1' and the CIA samples wr per `mos6526.v:123`: `wr = phi2_n & !cs_n & !rw`).

Why the v13g widening wasn't enough: in MCP mode the bridge's vpa/vda window doesn't always span the one-clk32 CYCLE_CPUD interval where phi2_n is high. Latch+replay decouples the bridge request window from the CIA sample edge.

Codex consult `codex_cia2_writeloss.txt` proposed this exact design.

### Verified effect on LOAD"$",8 (lorenz_disk1.d64)

| Metric | Problem C baseline (0c253fb4) | v14 (46c9def9) |
|---|---|---|
| PA stable value | $0F (124/125 frames) | $D7 (124/124 frames) |
| ATN asserted? | NO (bit 3 = 1) | YES (bit 3 = 0 → iec_atn_o = 1) |
| Wedge PC range | $00:$ED50/$EEB0/$EEB3 (LISTEN+ACPTR waiting for drive) | $00:$EAB4-$EACF (SCNKEY de-bounce) |
| IF counter | varying (IRQs taken) | $045E FROZEN |
| CIA1 TA | decrementing | decrementing (alive) |
| BASIC boot | ✓ | ✓ |

### Watch-out / known risk

v14 has a latent race when a queued CIA2 write fires at the same CYCLE_CPUC as a new CPU CIA2 read: the replay overrides cia2_rw/rs/db so the read sees the wrong rs. In practice MCP serializes I/O to one access per 1MHz period, so the pending queue is usually empty when a read arrives — but interleaved W/R loops with no slack could trip this. Not observed yet.

## 2. Next bug — CIA1 read race (SCNKEY de-bounce)

UART evidence after v14:
- PC concentrated in $00:$EAB4-$EACF (75-124 samples across 5s).
- IF=$045E frozen across 124 frames — CPU is INSIDE the IRQ handler infinitely.
- KERNAL SCNKEY at $EAAB does `LDA $DC01 / CMP $DC01 / BNE same-loop` to de-bounce; if two consecutive $DC01 reads disagree, it loops forever.

This is the **same wedge class** previously flagged in memory `mb_probe_003_misdiagnosis_pivot_2026-05-26`. It was masked earlier because the LOAD path got stuck much earlier (at $E5D5, then $ED50/$EEB0). Now that v14 lets the IEC protocol advance, the next bottleneck shows.

### Investigation handles

1. **CIA1 reads aren't latched.** `cia2_write_safe`-style timing protection is currently applied as a WRITE gate; READS go through ungated (line 2749: `cs_n => not (cs_cia1 and (not cpuWe or vpa_816 or vda_816))` → with `not cpuWe='1'` for reads, cs_n always asserts on cs_cia1). The CIA reads on phi2_n (also CYCLE_CPUD). If cs_cia1 falls between two phi2_n edges with different bus states, two consecutive `LDA $DC01` reads will return different bytes.
2. **Apply the same latch+replay pattern to CIA1 READS.** Different design than the write latch: read needs to return a value back to the CPU via bus_di_in. Capture the read at the next CYCLE_CPUC, hold cia2Do (CIA's db_out) stable across the bridge ack window so two adjacent CPU reads see the same byte.
3. **Side-effect care:** $DC0D (ICR) clears on read. The replay scheme must trigger the read EXACTLY ONCE per CPU access — easy to accidentally double-read. Same for $DC04-$DC07 (timer latches).
4. **Codex consult before building.** This is the right shape for a focused Codex prompt: "given the v14 fix is now in place and exposes a CIA1 read race in SCNKEY, sketch a latch-and-replay design for CIA1 reads that handles ICR side effects correctly."

### Sim status

`sim/scpu_async_bridge_tb/cpu_cia_real_tb.vhd` and `cpu_cia_rw_tb.vhd` both PASS in MCP mode at RATIO=2 — they use a 4-slot mock arbiter cadence with phi2_p/n at 1-out-of-4 slots, vs the real C64's 16-slot CPU portion (32 total) with phi2_n at 1-out-of-16. **The benches don't model the failing aperture and can't reproduce the bug.** A 16-slot bench is the right regression net per Codex's strategy section — deferred for next session.

## 3. Operator state

- `/tmp/mister_session.lock` = `agent=claude task=c64-problem-c-validate since=2026-05-27T02:09`.
- `/media/fat/_Test/C64.rbf` = v14 (md5 `46c9def9`).
- `/media/fat/_Computer/` untouched.
- Working tree clean.
- HEAD: `a0dd60e` on `milestone-b-cdc-rewrite`.

## 4. Pending / deferred

- **CIA1 read race fix** — next session. See §2.
- **16-slot GHDL regression bench** — Codex recommended adding after the fix lands on hardware. Defer.
- **v14 read/write race caveat** — if observed in practice (e.g., interleaved W/R wedge), add `cs_cia2='0'` gate to the fire condition so reads always win.
- **MGL `<file type="f">` PRG autoload** — disks mount but PRG element silently fails. Worked around with mtype.py + disk_ready mask fix (mount Empty.d64 or any disk first).
- **Bug 2 (kickstart SIMM-scan natural exit)** — orthogonal to MCP+LOAD path. Deferred.
- **Doom regression** — orthogonal. Current build needs MCP active for boot; passthrough='1' wedges kickstart per memory `btest_passthrough_breaks_boot_2026-05-27`.
