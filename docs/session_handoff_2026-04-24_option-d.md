# Session Handoff — 2026-04-24 — Option D + BRAM probe findings

## One-line status

Option D deployed. BRAM serves 192/195 reads (98.5%) in the $82-$8E range. Sim confirms both SDRAM and BRAM have correct bytes. The "$82-$8E corruption" premise from v62/v63 is **disproven**. Asterix still hangs — but not from memory corruption. Next session: pivot investigation to cache / buslogic / CPU.

## Key finding this session

**3 days of v91-v109 probe work was chasing a phantom.** The memory hierarchy (BRAM + SDRAM) is clean. Option D works as designed (BRAM serves the supposedly-corrupt range), but Asterix's black screen persists. Root cause is elsewhere.

Evidence:
1. Sim (`c64_sdram_pagetest_tb.vhd` extended with BRAM Port C probe): 0/4096 mismatches on both paths for $8000-$8FFF pattern write+readback
2. Hardware (v110 probe): `bram_hit_native` fires 192 times in $82-$8E; only 3 fall-throughs. Option D routing is functional
3. Hardware (prior builds): BRK cascade at $C003, SP drain, identical pattern with OR without Option D

## Files changed this session (all UNCOMMITTED)

**`C64_MiSTer/rtl/fpga64_sid_iec.vhd`** — multiple probe variants + Option D edits:
- **Option D Edit 1 (still in place):** `bram_hit_native` no longer gated on `emu_mode_816='0'`
- **Option D Edit 2 (REVERTED):** previously added `cache_flush_bank='1'` to `bram_pgvalid` clear — was sabotaging Edit 1 (decompressor writes $01 constantly, wiping pgvalid). Reverted.
- **v110 probe (added):** `bram_hit_82_cnt` / `fall_thru_82_cnt` counters, wired to W field via `dbg_irq_nmi_count`. Replaces the `hiram_drop_pc` probe.

**`sim/c64_reduced_harness/`** — BRAM verification infrastructure (SAFE TO COMMIT):
- `build_staging/c64_ram64k.vhd` — sim-only variant with Port C probe
- `build_staging/fpga64_sid_iec.vhd` — adds `bram_probe_addr`/`bram_probe_dout` entity ports
- `c64_reduced_top_v2.vhd` — passes BRAM probe through
- `c64_sdram_pagetest_tb.vhd` — reads both SDRAM and BRAM, compares
- `run_sdram_pagetest.sh` — uses staged c64_ram64k

## What the next session should do FIRST

Do NOT pursue Option D further. Do NOT keep adding probes in the $82-$8E range. Both are confirmed orthogonal to the bug.

**New investigation vectors**, in order of effort:

### 1. Vector-table integrity check (fastest)

$C003 is the latched HIRAM-drop PC from earlier probes. $C003 is USER RAM (not ROM). Something executed STA $01=$0x at $C003. Three possible causes:
- (a) Asterix legitimately wrote STA $01 as part of its init sequence; harmless
- (b) CPU took IRQ/BRK, jumped via $FFFE/$FFFF indirect, landed on garbage code at $C003
- (c) Self-modifying code overwrote $C003 with garbage after init

To discriminate: add a ring-buffer freeze on first `dbg_pc_816 = $C003`. Capture the 128 instructions leading up to it. If stack ops dominate → (b). If STA $01 is clean → (a). If foreign code → (c).

### 2. Cache coherency check

BRAM write path is correct. Cache (`cpu_cache.vhd`) is a separate 8KB cache with 1024×8 entries. Under turbo, cache can serve stale data if invalidation timing is wrong. Add a counter:
- `cache_hit_82_cnt`: count cache_hit_d1 events where `cpuAddr_pre[15:8]` in $82-$8E
- Compare to `bram_hit_82_cnt`. If cache also hits in this range, both paths are serving — they must agree on content.

### 3. Buslogic priority mux audit

`cpuDi` in fpga64_sid_iec has a multi-level priority mux (io_data > rom_stub > bram > cache > sdram > etc). If priority is wrong under some condition, wrong data wins. Code review the `cpuDi <= ... when ... else ...` chain starting around line 1189.

### 4. CPU instruction decode under turbo

$8055-$80AE is the main loop. 65C816-specific opcodes ($F4 PEA, $0B PHD, $AB PLB, $5C JML, $8B PHB). Per existing memory `project_asterix_v37_main_loop_running_no_vic_irq.md`: VIC IRQ never asserts. Possibility: CPU sets I flag via context-save pattern, never CLIs. Or PEA/PHD is pushing wrong bytes under turbo (CPU bench didn't cover this exact pattern).

### 5. VIC IRQ delivery path

Separate angle: maybe the CPU IS fine, but VIC's IRQ assertion never reaches the CPU's IRQ pin under turbo gating. Check `dbg_diag[7]` (NOT_irq_vic) over time — if stays low through the full main-loop window, VIC IRQ line is stuck deasserted.

## How to verify fix (once identified)

Success criteria (unchanged from prior handoff):
- Asterix title screen renders (visible in screenshot)
- UART A field shows addresses in $CBxx (game code) not BRK-cascade walk through RAM pages
- SP stable
- P register shows I=0 (CLI fired, raster IRQ taken)

## Invalidated prior memories / work

The following memories + probe builds were investigating a phantom root cause. Their observations may still be correct but the CAUSAL CHAIN is wrong:
- `project_sdram_pagetest_isolates_bug.md` (original) — now extended; SDRAM was always fine
- `project_asterix_scpuon_decompressor_hang.md`
- `project_asterix_v108_rom_off_pc_C003.md`
- `project_asterix_v109_hiram_drop_at_c003.md`
- All v91-v109 probe builds chasing $82-$8E bytes

Do not re-read these as if they point to the root cause. They document downstream symptoms.

## Decisions to lock in

- **KEEP Option D Edit 1** (BRAM serves emu mode $8000-$FFFF bank $00). It causes no harm and has a principled reason (matches real SuperCPU's 128KB SRAM). If any regression testing passes SCPU-OFF + SCPU-ON autorun_test.mgl with Edit 1, commit it standalone.
- **DO NOT commit Option D Edit 2** (cache_flush_bank in pgvalid clear). Confirmed to sabotage Edit 1.
- **DO NOT commit the v110 probe counters**. Single-use diagnostic.
- **DO commit the sim BRAM probe infrastructure** — it's reusable for future memory-hierarchy questions and passed cleanly.

## Context preserved

- `hiram_drop_probe` process is still in fpga64_sid_iec.vhd but no longer wired to `dbg_irq_nmi_count` — v110 probe replaced it. Restore by flipping `dbg_irq_nmi_count <= hiram_drop_pc;` if needed.
- All uncommitted RTL changes (966 line insertions) remain in working tree as WIP instrumentation.
