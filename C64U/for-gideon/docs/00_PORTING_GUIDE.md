# 65C816 SuperCPU on an FPGA C64 — implementation notes & porting guide

*Written for an external FPGA-C64 developer (e.g. the Commodore 64 Ultimate /
Ultimate-64 platform) who already has high CPU-clock headroom and might want to
add CMD SuperCPU (65C816) support. This distills a working MiSTer C64 SuperCPU
implementation plus the hard-won findings — especially **why the FPGA speed wall
that capped us at ~4 MHz is most likely a non-issue on a platform that already
runs the CPU at 64 MHz.***

This is a design/findings handoff, not a drop-in IP block — the integration is
intertwined with MiSTer's bus arbiter. The reusable parts (CPU core, register
map, memory model, and above all the timing analysis) are called out explicitly.

---

## 0. TL;DR — the one thing worth your time

We built a 65C816 SuperCPU into the VHDL MiSTer C64 core (Cyclone V, DE10-Nano).
It is **functionally complete and correct**:

- 65C816 native + emulation mode, 24-bit addressing, 16 MB SuperRAM.
- **Lorenz CPU test suite passes 100% in both 6510 (T65) and SuperCPU (65C816) modes.**
- Real SuperCPU native software runs (Doom and Wolfenstein 3D port boot into their
  engines from SuperRAM).
- SuperCPU register set + detection is VICE-`xscpu64`-validated.

**But it is capped at ~4 MHz effective**, and we proved exhaustively that every
lever to go faster is dead *on our FPGA/clocking*. The root cause is a single deep
**combinational** read path:

```
SDRAM dout → bus data mux (dataToCpu, ~17 levels) → cpuDi override mux (~15 levels)
           → P65C816.D_IN → ALU → AddrGen/PC   ≈ 20.5 ns total, of which ≈ 11 ns is
           *inside* the 65C816 core (di → ALU → PC)
```

On our 32 MHz system bus this only meets timing when the CPU is clock-enabled no
more often than every 4 bus cycles (a `set_multicycle_path -setup 2` budget) — i.e.
~4 MHz. Pushing the CPU clock-enable closer together, or raising the CPU clock,
violates that path. See §5 for the full autopsy and the list of falsified attempts.

**Why this is probably *your* opportunity, not your problem:** that path is long
in our design because each CPU read traverses (a) SDRAM latency and (b) a wide,
combinational, MiSTer-specific bus-priority mux. A platform that (1) already clocks
the CPU at 64 MHz and (2) feeds the CPU from fast local SRAM / a cache through a
tighter datapath has effectively already solved the dominant terms. The 65C816
core's own `di → ALU → PC` (~11 ns) is the only intrinsic limit, and at 64 MHz
with register retiming that is a normal closure problem, not a wall. **A demo like
"SuperCPU Kicks!" that we cannot run (it is gated behind a runtime *speed* check —
see §6) would very likely just work at your clock.**

---

## 1. CPU core

`C64_MiSTer/rtl/65C816/` — a CE-gated W65C816 core in VHDL, adapted from the SNES
core lineage (same family as the `P65C816` used in fpga-based SNES). Files:

| File | Role |
|------|------|
| `P65C816.vhd` | Top entity. CE-gated; std `CLK/RST_N/CE/RDY_IN/NMI_N/IRQ_N/ABORT_N`, `D_IN/D_OUT`, 24-bit `A_OUT`, `WE`, plus `VPA/VDA/MLB/VPB` bus-status. |
| `MCode.vhd` | Microcode (large — the full 65816 instruction matrix). |
| `AddrGen.vhd`, `ALU.vhd`, `AddSubBCD.vhd`, `BCDAdder.vhd` | Datapath. |
| `P65816_pkg.vhd` | Package/types. |

It is driven exactly like a 6510 wrapper: hold `CE` low to stall, pulse it to
advance one CPU cycle. `RDY_IN` is the bus-ready / VDA-VPA stall input.

**Integration gotchas we hit (all fixed in our tree, worth knowing):**

- **XCE / mode flags.** When forcing SP/X/Y narrowing on entering emulation mode,
  gate on `(P(0)='1' or P(8)='1')`, not just `P(0)`. (Index-width vs emulation-bit
  interaction.)
- **Relocatable Direct Page is used in the wild.** Real SuperCPU software does
  `PEA $D000 / PLD` to put the direct page over the I/O space and then accesses
  SuperCPU registers as zero-page (`STA $7E` → `$D07E`). Make sure your DP-relative
  addressing is exact — this is a real code pattern, not a corner case.
- **Combinational data-in.** The core latches `D_IN` on the CE edge; do **not**
  register the data mux feeding it unless you also add a CPU wait state — a
  registered `D_IN` adds a cycle the non-pipelined core can't overlap (this is the
  crux of §5).

---

## 2. Memory model

Full detail in `docs/supercpu_architecture_reference.md` (§2). Summary of the
*real* CMD SuperCPU map and **how our implementation differs** (your platform can
choose to be more faithful — we cut corners for FPGA fit):

| Region | Real SuperCPU | Our MiSTer implementation |
|--------|---------------|---------------------------|
| Bank $00 ($00xxxx) | 64 KB zero-wait SRAM; writes mirrored to C64 DRAM via 1-byte write buffer | SDRAM-backed, CPU runs in **SDRAM passthrough** (no SRAM/cache feeding CPU in the shipped build — see §3/§5). |
| Bank $01 | SRAM, holds write-protected ROM shadows (KERNAL/BASIC/CHARGEN copies) | Aliased onto bank $00 SDRAM (`bank01_mirror_to_00`). RAM-correct; ROM-shadow *reads* not implemented (no known consumer). |
| Banks $02–$EF | SuperRAM (PS/2 SIMM, 1/4/8/16 MB) | SuperRAM in SDRAM, starts at bank $02 (matches real HW). CPU executes directly from it. |
| Banks $F0–$FF | EPROM firmware when bootmap on; SuperRAM/open bus when off | Minimal ROM stub at $FF00; bootmap mostly off. |
| $D200–$D3FF | 512 B SuperCPU system/user RAM in the I/O hole | Not a real dprom (disturbed the fitter); 4 extent bytes synthesized in the read mux (see §4). |

Key facts that bit us and will matter to you:

- **REU and SuperRAM are separate memory systems.** REU DMA only touches C64
  motherboard RAM (bank $00), never SuperRAM. Software that wants REU→SuperRAM must
  do REU-FETCH → bank $00 → CPU long-store → SuperRAM. (Doom's loader does exactly
  this.)
- **SDRAM pipeline depth differs by region** in our build: bank $00 uses a 2-stage
  read, SuperRAM a 3-stage read. Whatever your fast memory is, the address mux into
  it **must be combinational** — registering it adds a 1-cycle latency that breaks
  `LDA long` across bank transitions.

---

## 3. Bus takeover / arbitration

MiSTer's C64 bus runs a 32-cycle wheel per 1 MHz period
(`EXT(8)+DMA(4)+VIC(4)+CPU(16)`); the VIC-II always runs at original speed and the
CPU gets clock-enables from the remaining slots. Our SuperCPU sits in this arbiter:
`supercpu_en` selects the 65C816 over the T65 6510, and the 65C816's `CE` is driven
from the CPU slots. Turbo = giving the CPU more/closer enables.

This is the **most MiSTer-specific layer and the least portable** — your platform
has its own bus/turbo scheme and you should keep yours. The reusable insight is the
*shape*: VIC-II at 1 MHz, CPU clock-enabled fast, a combinational mux selecting the
CPU's read data from {fast RAM, C64 DRAM/SDRAM, I/O, SuperCPU regs}.

`scpu_async_bridge.vhd` is our (ultimately HW-falsified) attempt at a clock-domain
bridge to run the CPU at 64 MHz over the 32 MHz bus — included for reference and as
a cautionary tale (§5), not as a recommended approach for you.

---

## 4. SuperCPU register map (as implemented + validated)

Authoritative read decode is in `fpga64_sid_iec.vhd` (the `cpuDi_nocache` mux,
~line 1991). Values cross-checked against VICE `xscpu64`'s `scpu64_hardware_read`
and against silicon.

**Detection / status ($D0Bx)** — software detects the SuperCPU here:
- `$D0B0` = `$40` (presence — the bit external software tests).
- `$D0B2` = `{hwenable, sys_1mhz, 000000}`.
- `$D0B6` = `{emu_mode, 0000000}`.
- `$D0B8` = `{speed_1mhz, speed_1mhz|sys_1mhz, 000000}`.
- `$D0B3/$D0B4/$D0B5` = optimization-mode / speed bits (we return these low; VICE
  returns `$80` in some — **benign, no software consumer we could find**; see §6
  where we proved a marquee demo does *not* read these at all).

**Control ($D07x)** — note real-HW vs our repurposing:
- `$D07A` = set fast (20 MHz) / `$D07B` = set slow (1 MHz). *Speed switch.*
- `$D07E` = enable SuperCPU hardware registers (`hwenable`); `$D07F` = disable.
- `$D076/$D077` = WriteSmart / optimization. We implement write-through (== optim
  mode 0); firmware writes them 9×, reads 0× — a confirmed **non-gap** for us.
- **`$D078`**: real HW = SIMM configuration. **We repurposed it as a cache-flush
  register.** If you implement a real cache + SIMM config, do *not* copy this.
- `$D27C–$D27F` = SuperRAM extent. We hardcode `00 02 00 F6` (first page lo,
  first bank=$02, last page lo, last bank+1=$F6) — matches VICE kickstart.

`$D07E` read returns the ROM-visible bit. The whole `$D0Bx` block is gated on
`scpu_regs_enabled`.

Differences-from-real-HW are also enumerated in `CLAUDE.md` ("Real SuperCPU vs
MiSTer Implementation") and `docs/supercpu_feature_status.md`.

---

## 5. The speed wall — full autopsy (the part that should interest you most)

We tried to exceed ~4 MHz many times. **Every approach was hardware-falsified, and
they all failed for the *same* root cause.** This is the map of the minefield so
you don't re-walk it — and the argument for why your platform sidesteps it.

**Root cause:** the CPU read-data path is deep and **combinational**:
`sdram.dout → dataToCpu (bus-priority mux, ~17 logic levels, fpga64_buslogic.vhd)
→ cpuDi override mux (~15 levels, fpga64_sid_iec.vhd) → P65C816.D_IN → ALU →
AddrGen/PCr`. ≈ 20.5 ns end-to-end; ≈ 11 ns of that is **inside** the 65C816
(`di → ALU → PC`). Our `C64.sdc` legitimately relaxes this with
`set_multicycle_path -setup 2 -to *P65C816:cpu|*`, valid *only* because the CPU
clock-enable is a sparse arbiter pulse ≥ 4 bus-cycles (clk32) apart. That is the
4 MHz cap, and it is honest.

Falsified levers (all reverted; build IDs in our git history / `session_handoff.md`):

| Attempt | What it did | HW result | Why it died |
|---------|-------------|-----------|-------------|
| **clk64** (Milestone B) | Run CPU at 64 MHz via async MCP bridge | Boots to READY, but **Lorenz wedges** | The bridge sustains the CPU enable across consecutive 64 MHz edges → invalidates the `-setup 2` multicycle → STA was **masking** real violations on the core's deep paths (15.6 ns budget). |
| **clk48** | Same bridge at 48 MHz, with an *honest* SDC (multicycle removed) | STA closes **+3.73 ns**, yet CPU **crashes** (PC into ZP) | Decisive: timing was genuinely positive but it still failed → a **functional/CDC hazard** in the sustain-enable bridge at any raised CPU clock, independent of timing. |
| **page-mode SDRAM** | Faster SDRAM controller | Breaks REU→SuperRAM transfer; no gain under realistic interleaved access | Real code interleaves bank $00 constantly → every SuperRAM read is a conflict-miss → win evaporates. |
| **SLOT3** | Re-space CPU grants to 3-clk32 (instead of 4) | CPU wedges at boot | 3-cycle spacing invalidates the same `counter[1]→counter[2]` multicycle that the deep mux relies on. STA masked it. |
| **BRAM read-cache + 2× alt-fire** | Cache bank $00/SuperRAM; fire CPU twice as often on hits | Cache is **correct** (shipped, disabled); the **2× alt-fire wedges** SuperRAM execution | Firing the consume path every 2 cycles collapses the di→ALU→PC window from ~62 ns toward ~31 ns where the core fails (−0.65 ns at setup-1). A data-validity gate cannot fix a *timing* violation on the consume path. |

**The shipped BRAM cache (`cpu_cache.vhd`) is correctness-only infrastructure** —
it caches coherently (bank-switch + DMA-snoop invalidation) but at the existing
4-cycle cadence, so it gives no speedup on our clocking. It exists because *a cache
is the right lever on a platform that can then fire the CPU faster* — which is you.

**The takeaway for a 64 MHz platform:** our wall is (SDRAM latency) + (a wide async
bus mux) + (the core's intrinsic ~11 ns). You have eliminated the first two by
construction (fast local memory, tight datapath, CPU already at 64 MHz). The
remaining ~11 ns `di → ALU → PC` is the real W65C816 critical path; at 64 MHz
(15.6 ns period) it is close but a candidate for ordinary register-retiming /
pipelining inside `ALU.vhd`/`AddrGen.vhd` — a bounded core-level task, not the
system-level dead end it was for us. That is the single highest-value thing to
attempt, and it is the only thing we could *not* do on our FPGA.

Deeper writeups: `docs/bus_architecture_and_speed_scaling.md`,
`docs/turbo_cache_architecture.md`, and the iteration logs in `docs/session_handoff.md`.

---

## 6. Compatibility status (what works, what's speed-bound)

- **Lorenz suite: 100% in both T65 (6510) and 65C816 modes.** This is the hard
  bar; the core is architecturally sound. (`tools/lorenz_run.py [t65|scpu]`.)
- **SST (single-step) oracle:** every remaining divergence is benign/intentional
  (e.g. RTI cycle-count, invisible to real software at turbo + raster-sync). No
  known real-software CPU bug.
- **Native software:** Doom and a Wolfenstein 3D port boot into their engines from
  SuperRAM (REU-FETCH loader → SuperRAM long-stores → `XCE`/`JML` into native code).
- **"SuperCPU Kicks!" (DMAgic, 1999) — speed-bound, not a bug.** We chased this as
  a compat defect and **proved it is a runtime *speed* gate**: in VICE `xscpu64`,
  `+speedswitch` (force 1 MHz) reproduces our hardware fallback exactly (lands in
  the identical `$81xx` loop, same "we still have a dream / requires SuperCPU with
  1 MB" fallback scroller), while default (~20 MHz) reaches the loader menu. We
  falsified every register-mismatch hypothesis (the demo reads **no** `$D0Bx`; not
  SIMM size; not `$D27x`; not a CIA-timer loop). **It needs effective MHz above its
  threshold (>4 MHz) — exactly what your platform has.** Detail:
  `docs/session_handoff.md` (iter-9) and the `scpu-kicks` analysis.

So the honest compat frontier for *us* is speed-bound; on a 64 MHz platform that
frontier likely moves substantially.

---

## 7. File manifest — port vs. skip

**Reusable (port / adapt):**
- `rtl/65C816/*` — the CPU core. Portable as-is (standard CE/RDY interface).
- The **register decode** (the `cpuDi_nocache` mux in `fpga64_sid_iec.vhd`, §4) —
  a clean spec of the SuperCPU register reads, VICE-validated.
- `rtl/cpu_cache.vhd` — coherent BRAM read-cache (bank-switch flush + DMA snoop
  invalidation). The mechanism is reusable even though it's disabled in our build.
- The **findings** in §5 and the docs — the timing analysis is the main deliverable.

**MiSTer-specific (do NOT port; keep your own):**
- `fpga64_sid_iec.vhd` bus arbiter / `sysCycle` wheel, `fpga64_buslogic.vhd` —
  intertwined with MiSTer's 32-cycle bus.
- `scpu_async_bridge.vhd` — our failed 64 MHz CDC bridge (reference/cautionary).
- `c64.sv`, `sys/` — MiSTer framework glue.
- `$D078`-as-cache-flush repurposing, the bank $01 mirror shortcut, the missing
  `$D200-$D3FF` dprom — FPGA-fit compromises, not faithful behavior.

**Test infrastructure worth borrowing:**
- `tools/lorenz_run.py` — keyboard-free Lorenz autoload via MGL (mode-selectable
  t65/scpu). The differential-against-VICE methodology (`xscpu64` as golden oracle,
  including `+speedswitch` to bisect speed-bound vs. functional bugs) is in
  `docs/debug_methodology.md`.

---

## 8. Provenance & contact

This is an experimental fork of the official MiSTer C64 core adding 65C816
SuperCPU support. RTL is VHDL/Verilog targeting Cyclone V; resource usage of the
full build is ~65% ALMs (27.4k/41.9k) and ~73% M10K on a 5CSEBA6U23I7, so there is
headroom. Everything here is offered as-is for adaptation.

The single most useful thing we learned and could not act on: **the SuperCPU is
functionally done and Lorenz-clean; the only barrier to real ~20 MHz operation is a
~11 ns core-internal datapath that an already-64 MHz platform is positioned to
close.** If that resonates, §1 (core), §4 (registers), and §5 (timing) are where to
start.
