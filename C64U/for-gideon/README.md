# SuperCPU (65C816) for an FPGA C64 — knowledge-transfer package

**For: Gideon Zweijtzer / the Commodore 64 Ultimate (Ultimate-64) platform.**
**From: an experimental MiSTer C64 fork that added CMD SuperCPU (65C816) support.**

---

## What this is

We spent ~6 months adding **CMD SuperCPU** support (WDC W65C816S, 24-bit
addressing, 16 MB SuperRAM, native mode, the SuperCPU register set) to the
open-source **VHDL MiSTer C64 core** on a Cyclone V (DE10-Nano).

The result is **functionally complete and correct**:

- 65C816 **native + emulation mode**, 24-bit addressing, 16 MB SuperRAM.
- **Lorenz CPU test suite passes 100%** in both 6510 (T65) *and* 65C816 modes.
- Real SuperCPU-native software boots into its engine from SuperRAM
  (a **Doom** port and a **Wolfenstein-3D** port; the **SuperCPU Kicks!** demo
  and **SynthMark64 / BoulderMark** benchmarks all run).
- The SuperCPU register set + software detection is validated against
  **VICE `xscpu64`** (cycle-level differential oracle) and against silicon.

The **one** thing we could *not* do is reach the SuperCPU's real ~20 MHz. We
hit a hard ~4 MHz ceiling — and we proved, exhaustively, that the ceiling is a
property of *our* FPGA's clocking + bus, **not** of the 65C816 core or the
SuperCPU semantics. **A platform that already runs the CPU fast from local
SRAM — i.e. yours — is positioned to walk straight through that wall.**

This package is the distilled, self-contained handoff: the reusable RTL, the
register/memory model, the test methodology, and above all the **timing
autopsy** that says *why* speed was our problem and probably isn't yours.

> This is a **design + findings handoff, not a drop-in IP block.** Our top-level
> integration is intertwined with MiSTer's bus arbiter (which you should keep
> your own version of). The portable parts — the CPU core, the register decode,
> the memory model, and the analysis — are called out explicitly below.

---

## Start here (reading order)

1. **`docs/00_PORTING_GUIDE.md`** — the main document. Written for you. The
   CPU core interface, the memory model, the register map, and §5 the full
   speed-wall autopsy with the argument for why your platform sidesteps it.
   *If you read one file, read this one.*
2. **`docs/06_LATEST_FINDINGS.md`** — everything we learned **after** the
   porting guide was written: the VICE `xscpu64` speed differential that
   localises the entire 4 MHz→20 MHz gap to **bank-$00 memory tier** (not the
   CPU), the k=2 datapath floor + why we can't pipeline, the first concrete
   rendering/timing divergence (Kicks-intro flicker), and the SIMM-detection
   fix. **Read this second** — it sharpens the guide's thesis with hard numbers.
3. **`docs/07_REGISTER_DECODE.md`** — the exact literal read-decode values
   ($D07x / $D0Bx / $D27x / native vectors), lifted verbatim from our RTL and
   cross-checked against VICE. A clean spec you can implement directly.
4. **`docs/01_CMD_SUPERCPU_ARCHITECTURE.md`** — vendor-independent CMD SuperCPU
   reference (memory map, boot sequence, register semantics), compiled from
   original docs + VICE source + community knowledge.
5. **`docs/02_FEATURE_STATUS.md`** — per-feature status: DONE / STUB /
   REPURPOSED / MISSING, where each lives in RTL, and how to regression-test it.
6. **`docs/03_CHANGES_VS_UPSTREAM.md`** — what we changed vs. stock MiSTer C64
   (Mermaid before/after, the dual-CPU mux, the bank-aware SDRAM addressing).
7. **`docs/04_ARCHITECTURE_DIAGRAMS.md`** — Mermaid diagrams of all variants
   (stock MiSTer, our SuperCPU build, real Ultimate-64, the planned target).
8. **`docs/05_DEBUG_METHODOLOGY_VICE_DIFFERENTIAL.md`** — how we used
   `xscpu64` as a golden oracle (incl. `+speedswitch` to bisect *speed-bound*
   vs *functional* bugs) and a bug-classification decision tree. Reusable
   directly — VICE is platform-independent.

---

## The reusable RTL (in `rtl/` and `roms/`)

| Path | What | Portability |
|------|------|-------------|
| `rtl/65C816/` | The CE-gated W65C816 CPU core (VHDL). `P65C816.vhd` top entity + `MCode.vhd` microcode + `ALU`/`AddrGen`/`AddSubBCD`/`BCDAdder` datapath + `P65816_pkg`. | **Port as-is.** Standard `CLK/RST_N/CE/RDY_IN/NMI_N/IRQ_N/ABORT_N` + `D_IN/D_OUT` + 24-bit `A_OUT` + `WE` + `VPA/VDA/MLB/VPB` bus-status. Driven exactly like a 6510 wrapper: hold `CE` low to stall, pulse to advance one cycle. |
| `rtl/cpu_cache.vhd` | A coherent BRAM read-cache (bank-switch flush + DMA-snoop invalidation). | **Mechanism reusable.** It is *disabled* in our shipped build — it caches correctly but gives no speedup at our 4-cycle CPU cadence. It is the right lever *once you can fire the CPU faster*. See `06_LATEST_FINDINGS.md` for why bank-$00 wants to be **SRAM**, not a cache, on a fast platform. |
| `roms/scpu64.mif` | The SuperCPU firmware ROM image (SOCI/SINGULAR open ROM, byte-identical to the one VICE `xscpu64` uses). 64 KB as a Quartus `.mif`. | **Same file works anywhere** — load via your ROM-mount mechanism. |

The CPU core's entity is reproduced in `00_PORTING_GUIDE.md §1`; the literal
register decode is in `07_REGISTER_DECODE.md`.

---

## The 60-second version of the speed argument

Our CPU read-data path is **deep and combinational**:

```
SDRAM dout → bus-priority data mux (~17 logic levels, MiSTer-specific)
           → cpuDi override mux (~15 levels)
           → P65C816.D_IN → ALU → AddrGen/PC      ≈ 20.5 ns total
                                                   (≈ 11 ns of it INSIDE the 65C816)
```

On our 32 MHz bus this only closes when the CPU is clock-enabled no more often
than **every 4 bus cycles** (`set_multicycle_path -setup 2`). That is the honest
~4 MHz cap. The VICE differential (`06_LATEST_FINDINGS.md`) then proves the
whole gap to 20 MHz lives in the **bank-$00 memory tier**: real SuperCPU runs
bank $00 from **128 KB zero-wait SRAM**; we run it from SDRAM passthrough.

**Two terms of our 20.5 ns are MiSTer-specific (SDRAM latency + the wide async
bus mux) and you've already designed them away.** What's left is the 65C816's
intrinsic ~11 ns `di → ALU → PC`. At your clock that's an ordinary
register-retiming / pipelining problem **inside `ALU.vhd` / `AddrGen.vhd`** — a
bounded core-level task, the single highest-value thing to try, and the only
thing we could not do on our FPGA.

---

## Licensing / provenance (please read before redistribution)

- **`rtl/65C816/`** derives from the open SNES-core P65C816 lineage. We have
  extended/fixed it (BCD, XCE mode flags, addressing). Check the upstream SNES
  core license for redistribution terms; treat our deltas as offered for reuse.
- **`rtl/cpu_cache.vhd`** and the integration logic were written for the MiSTer
  C64 core, which is **GPL**. The MiSTer C64 core itself is not included here.
- **`roms/scpu64.mif`** is the **SOCI/SINGULAR** open SuperCPU ROM (the same
  image VICE ships). Honour its license (it is an open-source SuperCPU OS).
- Everything in `docs/` is our own analysis, offered as-is for adaptation.

This was an unofficial research fork. Nothing here speaks for Commodore, CMD,
the MiSTer project, or VICE. If anything is useful, take it freely; if anything
is unclear, the porting guide names the exact source files and line ranges in
our tree so you can ask precise questions.

---

## Hardware/contact context

Our work targeted MiSTer (Cyclone V, DE10-Nano). We also own a physical
Ultimate-64 (used only as a differential reference via its REST API — we never
had bitstream sources for it; that's exactly why this is a handoff *to you*
rather than a fork we could ship ourselves).
