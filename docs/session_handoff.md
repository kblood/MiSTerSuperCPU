# Session handoff — 2026-05-23 (Step 7b alt-fire SuperRAM-only + long-opcode wall)

## TL;DR
1. **Step 7b alt_fire_r2 RTL added** (uncommitted as of writing this doc;
   commit comes with this file). Adds a CPU3/7/B/F alt-fire term ORed
   into `cpu_cyc`, gated on `scpu_fast_path AND cs_ram AND
   sdram_busy_cnt <= 1`. Bank-0 accesses keep the original 4-MHz cadence
   (boot path intact). SuperRAM accesses theoretically get 5 MHz.
2. **Step 7b RBF built & deployed** — `output_files/C64.rbf`, md5
   `108dd072`. Earlier confirmed: bank-0 ZP bench scales identically to
   pre-7b ($1166 ≈ $115A on full4x), so no bank-0 regression.
3. **SuperRAM-resident bench attempted but BLOCKED**: `STA al` and
   `LDA al` (long-mode opcodes $8F/$AF) crash → BASIC cold-start on
   both Step 7b AND v356 RBFs. Tested every variant (emu mode, native
   mode, with PHK/PLB, bank $00, bank $20, addresses $80/$500/etc).
   Existing `gen_sta_long_test.py` was aspirational — also crashes.
4. **Tooling fixes**: `tools/mister_debug.py` keys wrapper now properly
   tokenizes mixed text+key input (was typing the word "enter"
   literally). New `.claude/skills/mtype/SKILL.md` documents the mtype
   API and the wrapper gotcha.

## Where speed actually stands
- **Bank-0 CPU-bound**: 4 MHz cap empirically confirmed via
  `gen_cpu_bound_bench.prg` (CIA1 Timer A one-shot + ZP INC loop):
  off=$0451, smart4x=$044B, full4x=$115A → 4.02× scaling. Smart-mode
  doesn't help because `$D07A/$D07B` are stubbed.
- **SuperRAM throughput**: UNMEASURED. Step 7b's theoretical +25%
  benefit (4 MHz → 5 MHz) can only be validated by code that runs
  from bank $20, which our bench generator can't produce because long
  opcodes crash. Workaround: use Doom/Wolf3D frame rate as a proxy
  (Wolf3D pre/post-7b regression test = the actual validation).

## The STA al / LDA al crash discovery

Tested addresses, modes, RBFs:
| Variant                          | Outcome              |
| -------------------------------- | -------------------- |
| `LDA al $000080` emu (Step 7b)   | crashes              |
| `STA al $000080` emu (Step 7b)   | crashes              |
| `STA al $000500` emu (v356)      | crashes              |
| `STA al $200080` after XCE+SEP   | crashes              |
| `STA al $000080` after PHK/PLB   | crashes              |
| `CLC; XCE; SEC; XCE` (no long)   | works — labels OK    |
| `CLC; XCE; SEP #$30` (no long)   | works — labels OK    |
| `STA $D078` (regular abs)        | works — but flushes cache → loader crash if used while resident code is cached |

Microcode IS defined (`rtl/65C816/MCode.vhd:1309` for $8F STA LONG
emits 5 cycles AAL/AAH/AB then REGL→[AB:AA]). So the CPU dispatches
the instruction. The crash mechanism must be in:
- cpu_di mux not returning expected data on long-mode reads
- The SDRAM/cart_ce arbiter wedging when AB ≠ DBR
- The long-mode write path not reaching the I/O page when AB=$00

The bug has been silently present since at least v356. Doom and
Wolf3D never use long-mode loads/stores at runtime — they use REU
DMA to populate SuperRAM, then `JML $20:$xxxx` to execute, with
`PHK; PLB` to align DBR. That's why we never noticed.

## Roadmap for 10x

Current ceiling = 4 MHz. Target = 20 MHz (5x more) or interim 10 MHz
(2.5x more). Step 7b's +1 MHz (if it works) doesn't move the needle.

Real paths:
- **Phase F MCP redesign** (committed plan: `docs/async_bridge_mcp_handshake_plan.md`).
  Goal: clk_cpu=64 MHz with proper toggle-FF request/ack handshake.
  Theoretical 2× cap → 8 MHz. Multi-day rewrite. F.1c-f variants in
  memory all wedged via same-clock design flaw; needs F.1 rewrite at
  32 MHz to baseline-match first.
- **Reclaim EXT slots** for CPU. Memory says "EXT(8) + DMA(4) +
  VIC(4) + CPU(16) = 32 total per 1MHz period". Reclaiming all EXT
  slots → 16+8 = 24 CPU slots → +50% beyond current 4 MHz = 6 MHz.
- **Investigate STA al / LDA al crash** first — would unlock a real
  SuperRAM bench (currently we'd be measuring Step 7b blind via
  Wolf3D-frame proxies).

## Pre-emption: the long-opcode bug is the next chokepoint
Without working long-mode opcodes, any "SuperRAM workload" bench we
write has to embed itself via REU DMA. That's possible but high
overhead per iteration. Investigating the cpu_di mux + SDRAM long-path
routing is probably 1-2 days of GHDL bench work + UART probes.

Suggested order of business next session:
1. Decide: pursue (A) STA al fix first, then SuperRAM bench, or (B)
   Phase F MCP, or (C) ship Step 7b as-is and move to Wolf3D-proxy
   measurement.
2. If (A): GHDL bench targeting `STA al $00xxxx` in the existing
   `sim/p65c816_tb/` — reproduce or rule out CPU-side; if clean,
   reproduce in `sim/c64_reduced_harness/`.
3. If (B): start with F.0 prep + F.1 bridge rewrite at clk_sys (no
   PLL change yet).
4. If (C): commit Step 7b, baseline Wolf3D/Doom frame counts pre/post
   via UART F: counter, capture screenshots at fixed wall-times.

## State on disk now
- Working tree changes:
  - `C64_MiSTer/rtl/fpga64_sid_iec.vhd` — Step 7b (will be committed
    with this session)
  - `tools/mister_debug.py` — keys wrapper tokenizer fix
  - `tools/test_cart/gen_superram_bench.py` — bench generator (does
    not run due to long-opcode crash; preserved as reference)
  - `tools/test_cart/gen_test_steps.py` — bisect harness used to find
    the long-opcode crash
  - `.claude/skills/mtype/SKILL.md` — new skill
- MiSTer state: Step 7b RBF (md5 `108dd072`) deployed and loaded
  (current as of session end).
- `output_files/C64.rbf` and `builds/...108dd072-dirty.rbf` both hold
  Step 7b.

## Pointer to existing plans
- `docs/async_bridge_mcp_handshake_plan.md` — Phase F.0–F.5 (still
  the canonical multi-day path to 8 MHz).
- `docs/supercpu_feature_status.md` — feature-completion checklist.
- `.claude/skills/mtype/SKILL.md` — keyboard injection reference.
