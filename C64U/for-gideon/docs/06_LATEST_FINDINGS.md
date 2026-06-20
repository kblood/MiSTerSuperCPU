# Latest findings — what we learned after the porting guide

The porting guide (`00_PORTING_GUIDE.md`) was written mid-project. Everything
below is **newer** and sharpens its central thesis with hard numbers. Bottom
line up front:

> We built a true cycle-level differential against **VICE `xscpu64`** (a
> validated real-SuperCPU model) and a synthetic benchmark suite, and **localised
> the entire 4 MHz → 20 MHz gap to one thing: the bank-$00 memory tier.** Real
> SuperCPU executes bank $00 from **128 KB zero-wait SRAM**; we execute it from
> **SDRAM passthrough**. The 65C816 core itself is *not* the bottleneck — it
> already closes timing; it just *waits on memory*. On a platform with fast local
> RAM and a high CPU clock, this gap largely evaporates by construction.

---

## 1. The VICE `xscpu64` speed differential (the headline measurement)

We ran **SynthMark64** (a deterministic, single-load 65C816 benchmark that
prints a per-operation result table) on three configurations and compared the
*structure* and the *speed* of the output:

| Config | Effective speed | Notes |
|--------|-----------------|-------|
| Our core, 1 MHz default | **0.94×** | matches a stock C64 (correct by design — see §4) |
| Our core, turbo on (`$D07B`) | **2.85×** | our compat-safe emu turbo ceiling |
| **VICE `xscpu64`** (real-SuperCPU model) | **14.75×** | the reference |

**The result *table* is structurally identical across all three** — same 23
rows, same order, every row computes the same values. **Only the speed
multipliers differ.** That is the key compat finding: our rendering and
execution *match* VICE; what differs is purely throughput.

**Where the 2.85× → 14.75× gap lives**, from VICE's own per-operation breakdown:

- `compute` / `ram load` / `ram store` / `ram move` / `zeropage` rows:
  VICE **~20–21×**, us much lower. These are **bank-$00 memory** operations.
  *This is the entire gap.*
- `long store` / `long move` (SuperRAM, banks $02+): VICE ~15–18× (its SIMM is
  slower than its bank-$00 SRAM).
- `color RAM` / `I/O` rows: **1.77–4.0× even on VICE.** These touch the 1 MHz
  C64 bus and are **un-accelerable even on real hardware** — which is exactly
  why even a real 20 MHz SuperCPU benchmarks at 14.75×, not 20×.

**Interpretation for you:** the gap is *memory-tier*, not CPU. Real SuperCPU's
advantage is that bank $00 (zero page, stack, the hot working set) is
zero-wait-state SRAM at CPU speed. We feed bank $00 from SDRAM through the wide
combinational mux described in the porting guide §5. **Give the 65C816 fast
bank-$00/$01 SRAM at your CPU clock and you should land near VICE's numbers
without touching the CPU core.**

---

## 2. The k=2 datapath floor, and why we can't pipeline our way out

We shipped a **bank-$00 BRAM "fast-fire"** lever (native-mode only): when a
bank-$00 read is served from an on-chip authoritative BRAM, fire the CPU
**2-apart** (k=2) instead of the usual 4-apart. It works and is HW-validated
(Lorenz still 100%, Doom still runs, ~1.24–1.33× on Doom whose hot code is
bank-$00).

We then tried to go to **k=1** (fire on consecutive clk32 edges). A 15-second
`quartus_sta` on the fitted design **falsified it without a build**: the worst
CPU-internal path is `MCode addrInc → P[1]` (the **Zero flag**), data delay
**31.39 ns** vs the **31.72 ns** clk32 period — i.e. **−0.36 ns** at a 1-cycle
budget. The 65C816 datapath cannot complete a `result → flag` dependency in one
of our clock periods.

**Could we pipeline the core to break that path?** No — and this is important
for you to know before you try. Our 65C816 passes a **single-step test (SST)
oracle that compares every cycle's address/data/`VDA`/`VPA`/`RWB` against the
expected cycle count** (5.12 M cases, 0 failures). The core does D_IN-read +
ALU(BCD) + writeback **on one edge, even on internal cycles** (INX/DEX/TAX/CLC
write their register on the internal execute cycle). **Any** register inserted
to pipeline that shifts the next cycle → SST fails → cycle-exactness lost.
**The very property that makes the core correct (cycle-exact) is what forbids
pipelining it.**

**The escape hatch is the one we couldn't use:** ours is a *system-level* wall
(SDRAM + wide bus mux dominate). If your datapath into the CPU is short and your
clock is high, the residual ~11 ns `di → ALU → PC` is an ordinary
**register-retiming inside `ALU.vhd`/`AddrGen.vhd`** problem — and crucially you
can validate any such change against the **same SST oracle** we ship the
methodology for (`05_DEBUG_METHODOLOGY...`). If you keep the cycle counts
identical, you keep correctness; if you must trade cycle-exactness for a faster
fast-path, the SST tells you exactly which cycles moved.

---

## 3. First concrete *rendering/timing* divergence — and it confirms the thesis

Until recently every divergence from VICE was pure throughput. We then found
the first **rendering** divergence: the **SuperCPU Kicks!** DMAGIC intro draws a
cycle-timed raster-bar overlay over a text screen. On VICE it is rock-steady; on
our core **it renders correctly on some frames and collapses on others — it
flickers.**

We chased it hard and the conclusion is the same memory-tier story:

- It is **not** a pixel/VIC-II bug — the VIC-II *can* draw it; some of our frames
  match VICE exactly.
- It is a **raster-timing instability**: the overlay is written by a cycle-timed
  loop running from **bank $00**, which on our core runs at ~4 MHz effective with
  residual jitter (VIC badline cycle-steal, `$D021` I/O writes on the 4-apart
  SDRAM path, IRQ-entry latency). The per-line raster timing wobbles → the
  overlay misses its deadline on marginal frames.
- We tried two cheap fixes (uniform cadence; badline-independent bank-$00 reads).
  **Both HW-falsified.** The badline-independence one made it *worse*: advancing
  the bank-$00 code through VIC badlines de-synced the CPU from the raster
  further. The flicker is a delicate fast-code / 1 MHz-I/O-sync dance, not a
  single removable stall.

**Why this matters to you:** this is the same root cause as the speed gap, now
showing up as a *visual* defect. The demo was authored for a SuperCPU running
bank $00 from stable SRAM at 20 MHz. **A platform that runs bank $00 from fast
SRAM at a high clock would very likely run this overlay steady** — it reframes
"fast bank-$00 SRAM" as a **compatibility** lever, not just a speed lever. Some
cycle-timed SuperCPU software will *only* render correctly at (or near) real
SuperCPU bank-$00 timing.

---

## 4. The 1 MHz default is correct, not a gap (CMD contract)

A subtlety that cost us a wrong turn: by default our SuperCPU runs at **1 MHz**,
not turbo. **This is the correct CMD SuperCPU contract.** Turbo is opt-in:
software writes `$D07B` (or the OSD enables it). Stock BASIC and the Lorenz suite
never write `$D07B`, so they stay at the safe 1 MHz default — which is *why*
Lorenz passes 100% (timing-sensitive tests see real 1 MHz cadence).

We measured it on hardware (emu-mode BASIC, N=20000 jiffies):
`baseline 1397 → POKE 53371,0 ($D07B) → 346 (= 4.04×) → POKE 53370,0 ($D07A) →
back to 1397`. The speed switch works exactly as specified.

**Takeaway:** don't make turbo the default. Decode `$D07A`/`$D07B` and let
software (and your OSD) opt in. A SuperCPU that is *always* fast breaks
timing-sensitive 6510 code that the SuperCPU is supposed to run unchanged at
1 MHz until told otherwise.

---

## 5. A real compat fix worth copying — SIMM-detect 256-bank wraparound

SynthMark64 detected our SuperRAM as **0 KB** until we fixed this; the fix made
it read **15360 KB (240 banks)**. Root cause is a portable gotcha:

- SynthMark64's RAM-size probe walks banks $00 upward writing a ramp to
  `bank:$0400` and reading it back, with a **single-byte counter and no upper
  bound** — it only stops when a bank fails readback.
- We echo *all 256* banks, so the counter wraps `$FF → $00` → reports 0.
- Real HW reserves high banks (`$F0-$FF`) as **bootmap ROM (non-echoing)**, so
  the probe terminates there naturally.

**Fix:** cap SuperCPU CPU reads of banks `$F0-$FE` to a sentinel so the probe
stops at `$F0` (= 240 banks). **The sentinel value matters:** we first used
`$FF` and it *regressed Doom* (Doom's loader reads a high-bank pointer byte, got
`$FF` instead of the `$00` that empty banks hold → bad pointer → wedge). Using
**`$00`** (the real content of empty banks) fixed detection with zero behavioral
change for any reader that doesn't write-then-read those banks.

**For you:** if you map a real boot ROM into `$F0-$FF` (bootmap), you get this
behavior for free and don't need the cap. If your high banks echo RAM, expect
naive RAM-sizing probes to wrap — terminate them with non-echoing high banks.

---

## 6. Levers we proved dead (so you don't re-walk them)

All HW-falsified on *our* FPGA/clocking; listed so you can skip them or
recognise them. None of these are CPU-core bugs.

| Lever | Why it died on our platform |
|-------|------------------------------|
| Run CPU at 48/64 MHz via async CDC bridge | Boots, but Lorenz/CPU wedges — a functional CDC hazard in the sustain-enable bridge *independent of timing* (clk48 closed STA at +3.73 ns and still crashed). |
| Page-mode SDRAM | Doom row-locality measured ~54% (break-even ~45%) → ~1.1× best case; not worth a high-risk rewrite. Real code interleaves bank $00 constantly → conflict-misses. |
| Posted write buffer | Doom SuperRAM writes measured ~0.7% of accesses (read-dominated) → no ROI. Bulk writes go to bank $00 (VIC framebuffer) and aren't safely postable anyway. |
| 3-cycle CPU grant spacing (k=1 fast-fire) | Invalidates the `-setup 2` multicycle the deep mux relies on → masked-timing wedge (STA-falsified, §2). |
| BRAM read-cache + 2× alt-fire | Cache is correct, but firing the consume path 2× as often collapses the di→ALU→PC window toward where the core fails. A data-validity gate can't fix a *timing* violation. |
| Pipelining the 65C816 internals | Forbidden by SST cycle-exactness (§2). |

**The common thread:** every dead lever is either (a) a *timing* violation on
the deep combinational read path, or (b) a *memory-tier* limitation (SDRAM, not
SRAM, for bank $00). **Your platform attacks both root causes by construction**
— fast local memory and a high CPU clock — which is the whole reason this
handoff is aimed at you and not shipped by us.

---

## 7. One-paragraph recommendation

Port `rtl/65C816/` as-is, wire it like a 6510 (CE/RDY), give it **fast local
SRAM for bank $00 (and ideally bank $01)** and run it at your CPU clock.
Implement the register decode in `07_REGISTER_DECODE.md` (start with `$D0B0=$40`,
`$D0B6`, `$D07A/B`, `$D27C-F`). Keep speed **opt-in** via `$D07A/$D07B`. Validate
with the Lorenz suite in both modes and with the VICE differential methodology in
`05_DEBUG_METHODOLOGY...`. The 65C816 core is done and correct; the only frontier
left is the one your hardware is already built for.
