# SuperCPU v2 Feature Status — MiSTer Implementation

Snapshot date: **2026-04-25**. Compares the current MiSTer C64 SuperCPU core
against the CMD SuperCPU v2 specification (`docs/supercpu_architecture_reference.md`).
For each feature: status, where it lives in RTL, how to regression-test it,
and (for missing items) a sketch of how it could be added.

For the prioritized cross-lane work plan see `docs/roadmap.md`.

Legend:
- **DONE** — implemented and verified working
- **DONE-untested** — implemented but no automated regression coverage
- **PARTIAL** — implemented in part, with known gaps
- **STUB** — register reads/writes are decoded but the side-effect is missing
- **REPURPOSED** — MiSTer uses the address for something different than real HW
- **MISSING** — not implemented at all
- **BROKEN** — implemented but actively crashes or diverges from spec
- **N/A** — does not apply to FPGA implementation

---

## 1. Executive Summary

The MiSTer SuperCPU core implements the **functional core** of CMD SuperCPU v2:
65C816 native mode, 24-bit SDRAM-backed SuperRAM, register set, software speed
control, IEC slowdown, REU 16 MB, and writable native vectors. The 65C816 CPU
core itself is well-validated by GHDL benches.

**Three classes of issue currently block forward progress:**

1. **Active hardware bugs** (compatibility):
   - ~~**Asterix SCPU-ON hang**~~ — **FIXED 2026-04-27, commit `b267455`.**
     Root cause: M10K BRAM `no_rw_check` returned stale data on read-after-
     write to zero-page pointers `$2D`/`$2F`, hanging the dispatcher's
     handler 4/7 copy loops. Fix: cycle-N+1 write-data forward in
     `c64_ram64k.vhd`. Title bitmap renders, SPACE advances to gameplay.
     Do NOT drop `no_rw_check` — clk64 timing collapses (-8.5 ns slack).
   - **Doom K:2D state ambiguous** — earlier reports of deterministic crash;
     recent memory `project_doom_runs_mgl_only.md` (2026-04-18) shows 90s of
     stable Doom execution captured. Status needs re-verification.
   - **MGL pipe `<file>` PRG ioctl** — `echo load_core foo.mgl > /dev/MiSTer_cmd`
     reloads rbf but does not fire the PRG load ioctl in the current build.
     Workaround: `mbc load_rom` or `tools/mister_debug.py load_prg`. Not
     blocking, but should be diagnosed.

2. **Tooling blocker** (P0):
   - **Build-cache propagation** — RTL edits compile cleanly with new md5 but
     runtime UART behavior unchanged. Documented in
     `docs/session_handoff.md`. Blocks all hardware-verified probes.

3. **Spec gaps** (architecture / performance):
   - **Bank $01** routed to SuperRAM/SDRAM instead of SRAM shadow (real HW: 64 KB
     SRAM with KERNAL/BASIC/CHARGEN copies)
   - **WriteSmart optimization** ($D074-$D077, $D0B3) — STUB-COMPLETE.
     $D074-$D077 writes update `scpu_optim_mode`; $D0B4 / $D0BC / $D0B3
     reads decode (last added 2026-04-28). Mirror enforcement requires
     bank-$01 SRAM rearchitecture and stays gated until then.
   - **Write buffer drain** — `cacheable_wr=0`, FIFO infrastructure dormant.
     v159 (ungated) and v161 (gated on the new `wb_enable=supercpu_en`
     cache port) both built clean (ALMs 85-86 %, timing met) but black-
     screened on hardware. Root cause: `cache_hit_d1` fires the SDRAM-
     pipeline cancel during CPUA-CPUD; `enableCpu_816`'s substitute path
     is gated `not at_cpucd`, so the substitute mis-fires exactly when
     `wb_drain_active` hijacks `ramAddr/ramDout/ramWE`. The CPUC slot
     loses both the new SDRAM write and the BRAM mirror. Next attempt
     must either (a) suppress `wb_drain_active` for one cycle after a
     fresh push, or (b) defer cache absorption to CPUE-CPU9 (outside
     the at_cpucd window).
   - **DOS extension** ($D0BE/$D0BF), **bootmap ROM** ($F0-$FF) — MISSING/STUB
   - **$D078** — REPURPOSED for cache flush; real HW = SIMM config
   - **$D086 OSD bit (SCPU Kickstart ROM)** wired 2026-04-28 (commit pending):
     `scpu_rom_opt = status[86] & supercpu_enable`. Default Off; previously
     hardcoded to `1'b0` on the diagnostic path. Lets users opt back into the
     kickstart-ROM overlay without rebuilding the bitstream.

**Recent corrections to this doc** (since prior version):
   - **$D200-$D3FF I/O hole RAM** — promoted from MISSING to DONE; was
     already implemented in `fpga64_buslogic.vhd:132-303`. Verified via
     `sim/scpu_sysram_tb/` (0/512 mismatches).

**Performance**: ~4 effective MHz, measured. Cap is the disabled write buffer +
missing WriteSmart, NOT CPU clock. Realistic ceiling on Cyclone V is ~10-15 MHz
once Phase B (write buffer drain) lands. 20 MHz parity is unlikely without
abandoning SDRAM and moving the C64 RAM into dedicated BRAM/SRAM.

---

## 2. Active Bug Tracker

Distinct from "missing features" — these are things that should work but don't.

### 2.1 Asterix SCPU-ON hang (FIXED 2026-04-27, commit `b267455`)

**Root cause**: `c64_ram64k.vhd` was inferred as M10K with
`READ_DURING_WRITE_MODE = DONT_CARE` via `attribute ramstyle … "M10K, no_rw_check"`.
On Cyclone V, this leaves the registered read output undefined when the same
address is being written. Asterix's relocator copies a 256-byte dispatcher
to `$0100-$01FF` (low-byte handler table at `$011A-$0121` =
`A8 4A AF 7D 5C 42 46 30`) and runs it under SCPU turbo. Two of the handlers
read zero-page pointers immediately after incrementing them:

* Handler 7 at `$0130` — `LDA ($2F),Y` then `JSR $0122` to advance `$2F`.
* Handler 4 at `$015C` — `STA ($2D),Y` then `INC $2D / BNE` repeating
  X·`$39` times.

Inside the M10K RAW window the registered read returned the previous byte,
so `$2D` / `$2F` appeared frozen and the loops never exited. Decompression
never reached `$01A8 → JMP $CB00` so the title bitmap never rendered.

**Fix** (`C64_MiSTer/rtl/c64_ram64k.vhd`): register the most recent write
into a 1-deep `(a_we_d1, a_din_d1)` capture and forward `a_din_d1` on
`a_dout` whenever `a_we_d1='1'`. Address comparison is unnecessary because
both the M10K read latch and the capture register sample the same `a_addr`
at the same edge — a write at cycle N and the registered read at cycle N+1
target the same location. Adds a few flops + an 8-bit mux, timing-safe.

**Do NOT drop `no_rw_check`**. v157 attempt to use plain `"M10K"` (let
Quartus infer write-first) blew worst-case clk64 slack to **-8.562 ns**
(TNS -49866 ns) and bumped ALMs to 85 % — Cyclone V M10K cannot meet
64 MHz with the forwarding muxes Quartus inserts. Keep the bypass.

**Hardware verification** (rbf md5 `5844c1b89bb329d2fb02f541a74565ea`):
* `mbc load_rom C64 /media/fat/games/C64/asterix.prg` (or
  `tools/mister_debug.py load_prg`) — title bitmap renders ("SCE PRESENTS /
  ASTERIX. / HIT SPACE TO START") with horizontally scrolling cracker
  credits. Reproducible across cold reloads.
* SPACE advances to "ASTERIX AND THE MAGIC CAULDRON" gameplay screen
  with sprite characters animating on the ground tiles.
* Vanilla C64 BASIC still boots clean post-fix (no regression).

**Auxiliary instrumentation** added in the same commit: `dbg_max_pc_r`
in `fpga64_sid_iec.vhd` (monotonic max PC at PBR=$00, exposed via the
UART `W:` field) — useful for future "decompressor stuck" symptoms;
W>$01FF means SCPU code escaped the dispatcher page; W≥$CB00 means
decomp reached game entry.

### 2.2 Doom K:2D state (AMBIGUOUS, needs re-test)

**Older narrative** (2026-03-22, this doc's prior version):
- Deterministic crash at K:2D → K:00 transition with bit-for-bit identical state
  across 3 hardware runs. Last good fetch K:2D A:037D, first bad K:00 A:0111.
- Interpretation: PC ran into uninitialized memory near $2D:$FFE6.

**Newer narrative** (2026-04-18, `project_doom_runs_mgl_only.md`):
- 90s stable Doom execution captured with MGL + launcher. No loader.prg needed.
- X-flip trigger did NOT fire in that window.
- Prior "Doom crashes" observations may have been mtype keyboard timing failures.

**Action required**: re-run Doom with current head commit and resolve which
narrative is current. Add to compatibility lane in roadmap.

### 2.3 Build-cache propagation (RESOLVED 2026-04-25, not a real bug)

**Outcome**: Investigation confirmed build pipeline is correct end-to-end.
Local rbf md5 matches deployed rbf md5; only 3 C64*.rbf files on MiSTer;
no shadow rbfs. The "didn't propagate" symptom in the prior session was a
file-mtime sequencing artifact: source edits were made AFTER the build
finished, so any UART observation reflected the OLD build, not post-edit
state. Verify source mtime < rbf mtime before claiming an edit was lost.

**Impact**: hardware iteration is unblocked. Asterix probes can resume.

### 2.4 XCE M/X auto-force (WORKAROUND, may be obsolete)

**Symptom**: Initial XCE doesn't force M=X=1 cleanly. Software workaround:
add `SEP #$30` after `XCE`.

**Action required**: GHDL bench `test_xce_fixed.prg` to verify whether this is
still required after recent CPU-core fixes (SR-emu-wrap, SP-emu-wrap). If no
longer needed, remove workaround documentation.

---

## 3. CPU Core (P65C816)

| Feature | Status | RTL location | Notes |
|---|---|---|---|
| 65C816 instantiation | DONE | `c64.sv:1100-1180`, `rtl/cpu_65c816.vhd` | Stock P65C816 from SNES core, wrapped to 6510-compat interface. |
| Native mode (E flag) | DONE | `cpu_65c816.vhd:168` | CLC/XCE switches to native. |
| 16-bit M / X / S | DONE | core internal | REP/SEP work; 16-bit S debug-exposed. |
| MVN / MVP block move | DONE | core + phantom-cycle bypass `8f580b8` | All 6 MVN/MVP regression tests pass. |
| JML / JSL / RTL | DONE | core | 24-bit addressing. |
| Native vectors $FFE4-$FFEF | DONE-writable | `fpga64_sid_iec.vhd:419-428, 2064-2079` | 14-byte writable RAM. Boot-default = $FF00 (RTI/RTL). |
| XCE M/X auto-force | WORKAROUND | `cpu_65c816.vhd` | See bug 2.4 — re-test required. |
| Reset / mode-select mux | DONE | `fpga64_sid_iec.vhd:1270, 1292` | Inactive CPU held in reset. |
| NMI / IRQ wiring | DONE | `cpu_65c816.vhd:86-87`, `fpga64_sid_iec.vhd:75-77` | NMI edge-detect + ack. |
| VPA / VDA | DONE | `cpu_65c816.vhd:94-95`, `fpga64_sid_iec.vhd:1254-1255` | Gates I/O slowdown. |
| **SP emu-mode wrap (LOAD_SP 110/111)** | DONE | `P65C816.vhd` | Fixed 2026-04-20 commit `0d62500`. Affects $0B/$22/$2B/$62/$6B/$AB/$D4/$F4/$FC. |
| **Stack-relative emu-mode page wrap** | DONE | `P65C816.vhd` AddrGen | Fixed 2026-04-21 commit `6edec4c`. Affects $A3/$83/$C3/$E3/$F3 etc. |
| **Turbo-mode BRAM write-through** | DONE | `fpga64_sid_iec.vhd` | Fixed 2026-04-23 commit `ece1314`. SuperCPU bank-$00 writes. |

**Test strategy:**
- **Existing**: GHDL bench `sim/p65c816_tb/` covers 4 scenarios in one elaboration (~5s end-to-end). Plus topic-specific benches: `p65c816_sr_emu_wrap_tb.vhd`, `p65c816_copy_loop_tb.vhd`, `p65c816_asterix_full_tb.vhd`, `p65c816_xtransition_*_tb.vhd`. Use for any CPU-class change.
- **Existing**: MVN/MVP regression PRGs (6 tests, all pass).
- **Existing**: `test_xce_fixed.prg` for XCE switching.
- **Gap**: No standardized 65C816 test suite (e.g., the WDC validation suite). Acme8 / Lorenz-equivalent regression for 65C816 would be valuable.

---

## 4. Memory Map — Bank $00

| Region | Status | RTL location | Notes |
|---|---|---|---|
| $0000-$0001 (CPU port) | DONE | `cpu_65c816.vhd` | Handled by wrapper. |
| $0002-$7FFF RAM | DONE | `rtl/c64_ram64k.vhd` | 64 KB dual-port BRAM. |
| $8000-$CFFF RAM | DONE | same | Extended from 32 KB to 64 KB at commit `1120e84`. |
| $D000-$DFFF I/O | DONE | `fpga64_buslogic.vhd` + `fpga64_sid_iec.vhd:1250-1256` | I/O slowdown via VPA/VDA. |
| $D200-$D2FF SCPU sys RAM | **DONE** | `fpga64_buslogic.vhd:132-303` | 512-byte array w/ reset sweep. Verified `sim/scpu_sysram_tb/`. |
| $D300-$D3FF SCPU user RAM | **DONE** | same | Same 512-byte array. Verified. |
| $E000-$FFFF KERNAL | DONE | bootmap path | Bootmap=1 cold boot, bootmap=0 BRAM shadow. |
| Native vectors $FFE4-$FFEF | DONE-writable | `fpga64_sid_iec.vhd:2064-2079` | |
| BRAM hit fast path | DISABLED | `cpu_cache.vhd` (`bram_hit_d1`) | Per-page valid too coarse. Cache covers $0000-$FFFF instead. |

**Test strategy:** Boot to BASIC READY = smoke test. Lorenz 6510 covers compat. **Gap**: No targeted regression for 64 KB BRAM beyond Doom — recommend a `bram64k_test.prg` walking RAM with patterns.

---

## 5. Memory Map — Banks $01-$FF

| Bank range | Spec (real HW) | MiSTer | Status |
|---|---|---|---|
| $01 | 64 KB SRAM (KERNAL/BASIC/CHARGEN shadow) | SDRAM SuperRAM | **WRONG** |
| $02-$EF | SuperRAM (PS/2 SIMM, 1-16 MB) | SDRAM `{1, bank[7:0], addr[15:0]}` | DONE — 3-stage pipeline |
| $F0-$FF (bootmap=0) | SuperRAM | SDRAM | DONE for code; ROM stub overlay $FF00-$FFEF only |
| $F0-$FF (bootmap=1) | EPROM (SuperCPU OS, 64-512 KB) | Minimal stub (RTI/RTL at $FF00) | PARTIAL |
| Bank crossing in JML/JSL | DONE | core | Verified end-to-end. |
| Bank $01 SRAM shadow | MISSING | — | Real HW writes ROM copies here at boot. |

**Implementation gap — Bank $01 SRAM shadow:**
M10K constrained at 95% — adding 64 KB more is not feasible without freeing
elsewhere. Workable compromise: 16 KB BRAM region for $01:A000-$01:DFFF (BASIC +
CHARGEN); for $01:E000-$01:FFFF (KERNAL) reuse the 64 KB BRAM via bank-bit
aliasing trick. Boot stub copies ROM during first ~256 cycles. **Medium** lift
(~3-5 days). Sequence after Asterix/Doom stable.

**Test strategy:** **Gap**: No regression PRG for bank $01. Recommend a test that
copies known patterns to $01:0000, $01:8000, $01:FFFF and reads back via long
load.

---

## 6. Register Map ($D072-$D0BF)

| Reg | Spec | MiSTer status | RTL location |
|---|---|---|---|
| $D072 | sys 1 MHz enable | DONE | `fpga64_sid_iec.vhd:2083-2086` |
| $D073 | sys 1 MHz disable | DONE | same |
| $D074 | VIC bank 2 opt | STUB | `fpga64_sid_iec.vhd:2108-2115` |
| $D075 | VIC bank 1 opt | STUB | same |
| $D076 | BASIC opt | STUB | same |
| $D077 | No-opt | STUB | same |
| $D078 | SIMM config | REPURPOSED → cache flush | `fpga64_sid_iec.vhd:2102-2103` |
| $D079 | sw turbo (alias for $D07B) | DONE | `fpga64_sid_iec.vhd:2104-2107` |
| $D07A | sw 1 MHz enable | DONE | same |
| $D07B | sw turbo enable | DONE | same |
| $D07D | HW reg disable (alias) | DONE | `fpga64_sid_iec.vhd:2087-2101` |
| $D07E | HW reg enable | DONE | same |
| $D07F | HW reg disable | DONE | same |
| $D0B0 | mode detect | DONE (returns $40 = v2/64) | `fpga64_sid_iec.vhd:890` |
| $D0B2 | HW enable + sys 1 MHz | DONE | `fpga64_sid_iec.vhd:892` |
| $D0B3 | enhanced optimization (V2) | MISSING | — |
| $D0B4 | optimization mode flags (R) | DONE | `fpga64_sid_iec.vhd:895` |
| $D0B5 | JiffyDOS / speed switch | DONE | `fpga64_sid_iec.vhd:897` |
| $D0B6 | bootmap disable | DONE | `fpga64_sid_iec.vhd:2119-2123` |
| $D0B7 | bootmap enable | DONE | same |
| $D0B8 | sw speed flag | DONE | `fpga64_sid_iec.vhd:894` |
| $D0BC | DOS extension mode | PARTIAL (R only, no W) | `fpga64_sid_iec.vhd:889` |
| $D0BE | DOS extension enable | MISSING | — |
| $D0BF | DOS extension disable | MISSING | — |
| $D200-$D2FF | system RAM (SCPU OS) | DONE | `fpga64_buslogic.vhd:132-303` (verified) |
| $D300-$D3FF | user RAM (SCPU programs) | DONE | same (verified `sim/scpu_sysram_tb/`) |

**$D200-$D3FF (DONE):**
Implemented in `fpga64_buslogic.vhd:132-303` as a 512-byte register array.
Reset sweep clears all locations on system reset (prevents kickstart
warm-boot path). cs_vic suppression at line 503 (`cs_vic <= cs_vicLoc and
io_enable and not scpu_sysram_cs and scpu_io_en`) prevents VIC mirror
collision. Decode: `supercpu_en='1' and supercpu_bank=$00 and
cpuAddr(15:9)="1101001"`. **Verified** by `sim/scpu_sysram_tb/` (writes
pattern (addr XOR $42) over all 512 addresses and reads back; 0/512
mismatches). Status was incorrectly listed as MISSING in prior versions
of this doc.

**Implementation gap — $D0BE/$D0BF DOS extension:**
JiffyDOS-style fast loaders + SuperCPU file extensions. Most non-IEC software
ignores it. **Low priority** unless specific software demands it.

**Implementation gap — WriteSmart ($D074-$D077, $D0B3):**
LARGEST functional + performance gap. WriteSmart controls which bank-$00 writes
mirror to slow C64 DRAM. In MiSTer the analogous mechanism is what to write to
SDRAM vs cache-only. With `cacheable_wr=0`, every write hits SDRAM (slow).

To implement WriteSmart equivalents:
1. Define `optim_mirror_mask` from `scpu_optim_mode`:
   - `$D077` (no-opt): mirror $0000-$FFFF
   - `$D076` (BASIC): mirror $0400-$07FF only
   - `$D075` (VIC bank 1): mirror $4000-$7FFF only
   - `$D074` (VIC bank 2): mirror $8000-$BFFF only
2. For writes IN mirror mask: existing slow SDRAM path (so VIC sees data).
3. For writes OUTSIDE mirror mask: write to cache + 64 KB BRAM only.
4. Re-enable `cacheable_wr=1` for the cache path.
5. V2 enhanced ($D0B3): exclude ZP ($00-$FF) and stack ($100-$1FF).

Gated by getting write-buffer drain working (Phase B from
`docs/architecture_diagrams.md`). **~5-10 days**, high payoff (4 MHz → 10-15 MHz).

---

## 7. Speed Control

| Feature | Status | RTL location | Notes |
|---|---|---|---|
| `turbo_mode` equation | DONE | `fpga64_sid_iec.vhd:2338-2384` | sys/soft/sw priority. |
| OSD speed selection (max/4x/2x/1MHz) | DONE | same | From `scpu_speed[1:0]`. |
| IEC auto-slowdown (32 ms) | DONE | `fpga64_sid_iec.vhd:2157-2187` | CIA2 detect. |
| 1 MHz badline emulation | PARTIAL | `fpga64_sid_iec.vhd:1250-1256` | I/O slowdown OK; no VIC badline stalls during turbo. |
| Optimization-mode write mirroring (WriteSmart) | MISSING | — | See §6. |
| Physical 1 MHz switch (hwenable override) | N/A | — | OSD substitutes. |

**Measured performance** (hardware verified, not theoretical):
- **Cache-heavy workload** (Doom main loop): ~4 effective MHz.
- **Cache hits/frame**: ~1400-2900 depending on resident set.
- **Enables/frame**: ~7300-7600.

**Theoretical ceiling on current architecture**: ~12 MHz with Phase B (write
buffer drain + cacheable_wr re-enabled). 20 MHz requires lookahead (Phase C)
which probably won't fit in M10K budget.

---

## 8. Cache and Write Buffer

| Feature | Status | RTL location | Notes |
|---|---|---|---|
| 8 KB direct-mapped cache | DONE | `rtl/cpu_cache.vhd` | MLAB tags + M10K data. |
| Per-byte valid bits | DONE | `cpu_cache.vhd` | 1024 × 8-bit. |
| Cache fill from SDRAM | DONE | `cpu_cache.vhd` | |
| Cache invalidation on CPU write | DONE | `cpu_cache.vhd:209-214` | |
| Cache flush via $D078 | DONE | `fpga64_sid_iec.vhd:2102-2103` | Repurposed; sweeps cache + BRAM page-valid. |
| Cache flush on PRG inject | DONE | commit `8ef779f` | bram_invalidate added. |
| Write buffer FIFO (16 entries) | INFRASTRUCTURE | `cpu_cache.vhd:105-117` | Registers exist; drain logic disabled. |
| Write absorption (`cacheable_wr`) | DISABLED | `cpu_cache.vhd:203` | Hardcoded 0. All writes through SDRAM. |
| BRAM hit fast path (`bram_hit_d1`) | DISABLED | `cpu_cache.vhd` | Per-page valid too coarse. |
| Option D (BRAM serves emu mode $8000-$FFFF) | EVALUATED | `fpga64_sid_iec.vhd` | Edit 1 works; doesn't fix Asterix. Edit 2 reverted. |

**Test strategy:**
- **Existing**: Cache hit/enable counters in UART overlay (C: and N:).
- **Existing**: Sim pagetest `c64_sdram_pagetest_tb.vhd` proves SDRAM + BRAM clean to/from $80xx.
- **Gap**: No automated cache-coherency regression. Recommend `cache_coherency.prg` walking write-flush-read patterns.

---

## 9. REU / DMA

| Feature | Status | RTL location | Notes |
|---|---|---|---|
| REU register file ($DF00-$DF0A) | DONE | `c64.sv:725-742` | Standard 17xx. |
| FETCH (REU→C64) | DONE | `c64.sv` | Verified via Doom loader. |
| STASH (C64→REU) | DONE-untested | same | |
| SWAP / VERIFY | DONE-untested | same | |
| 16 MB REU when SuperCPU active | DONE | `c64.sv:639-641` | OSD override. |
| REU SDRAM region | DONE | `c64.sv:929, 1197` | `REU_ADDR + 25'h20000`. |
| REU → SuperRAM coupling | NOT POSSIBLE BY DESIGN | — | Two separate systems. |
| OSD REU file load | DONE | MiSTer framework | USB drive only (SD-card REU broken in upstream). |
| **REU IOF falling-edge fix** | DONE | `fpga64_sid_iec.vhd` (iof_fall_pulse_r) | Commit 2026-04-13. Required for turbo writes. |
| **REU diagnostic registers $DFA1-$DFBF** | DONE | `fpga64_sid_iec.vhd` | CPU-readable counters. |

---

## 10. Dual-CPU Mux and Bus Logic

| Feature | Status | RTL location | Notes |
|---|---|---|---|
| `supercpu_en` mux | DONE | `fpga64_sid_iec.vhd:1270, 1292, 1324-1334` | Inactive CPU held in reset. |
| Bank byte routing | DONE | `fpga64_sid_iec.vhd:294, 1709` | `addr_hi_816` from CPU. |
| `enableCpu_6510` / `enableCpu_816` | DONE | `fpga64_sid_iec.vhd:1232-1262` | Per-CPU enable. |
| 32-slot bus arbitration | DONE | `fpga64_sid_iec.vhd` (sysCycleDef) | EXT/DMA/VIC/CPU. |
| SDRAM address mux | DONE | `c64.sv:1178-1205` | |
| `scpu_sdram_addr` combinational | DONE | `c64.sv:1316-1320` | Must NOT be registered. |
| **6510 path simplification** | DONE | commit `25bf8ad` | `enableCpu_6510 <= enableCpu and not dma_active` when `supercpu_en='0'`. Restored SCPU-OFF compat. |
| **enableCpu_816 simplification** | NOT POSSIBLE | — | Tried; deadlocks. Cache/BRAM hits load-bearing in SCPU path. |

---

## 11. Simulation Infrastructure

| Component | Status | Location | Coverage |
|---|---|---|---|
| GHDL P65C816 bench | DONE | `sim/p65c816_tb/` | 4 base scenarios + 8+ topic benches. ~5s end-to-end. |
| SR-emu-wrap bench | DONE | `sim/p65c816_tb/p65c816_sr_emu_wrap_tb.vhd` | Validates AddrGen fix. |
| Copy-loop bench | DONE | `sim/p65c816_tb/p65c816_copy_loop_tb.vhd` | abs,Y + INY + BNE; (zp),Y wrap. |
| Asterix phase-1 bench | DONE | `sim/p65c816_tb/p65c816_asterix_phase1_tb.vhd` | Reaches Y=$00. |
| Asterix full bench | DONE | `sim/p65c816_tb/p65c816_asterix_full_tb.vhd` | Reaches $CB00 in 312ms sim. |
| X-flag transition bench | DONE | `sim/p65c816_tb/p65c816_xtransition_*` | Rules out CPU bug. |
| Reduced-system harness | DONE | `sim/c64_reduced_harness/` | Real cpu_65c816 + cpu_cache + c64_ram64k + buslogic + VIC + simple_sdram_model. |
| SDRAM+BRAM pagetest | DONE | `sim/c64_reduced_harness/c64_sdram_pagetest_tb.vhd` | Verifies write/read paths in $80xx. |
| PRG loader bench | DONE | `sim/prg_loader_tb/` | ioctl PRG inject path. |
| Verilator vanilla | DONE-shelved | `sim/verilator_c64_vanilla/` | Reference comparison only. |
| Verilator SuperCPU fork | SHELVED | branch `shelved/verilator-superfork` | Removed 2026-04-18. |
| **VICE PC-trace diff harness** | MISSING | — | See `docs/roadmap.md`. Highest-leverage planned addition. |

---

## 12. Doom Status

**Loading**: WORKS — MGL with absolute-path REU file load + launcher SYS sequence.

**Runtime**: AMBIGUOUS — see bug 2.2. Older "deterministic crash" narrative
contradicted by 2026-04-18 "90s stable execution" capture. Re-test required.

**REU FETCH path**: WORKS — verified end-to-end via diagnostic counters.
**Bank crossing JML/JSL**: WORKS — Doom uses banks $20, $29-$2D, $80, $BD.
**Math tables in $10-$19**: WORKS — `STA [$dp],Y` indirect long.

**Doom-specific recipe** (after MGL load):
```
POKE49152,120:POKE49153,24:POKE49154,251:POKE49155,92
POKE49156,0:POKE49157,0:POKE49158,32
SYS49152
```
Assembles `SEI; CLC; XCE; JML $20:0000`.

---

## 13. Recommended Next Steps (priority order)

See `docs/roadmap.md` for the dependency-ordered three-lane plan. Headline:

1. **P0 — Build-cache propagation** (blocks everything that needs hardware verification)
2. **Asterix root-cause** (unblocks compatibility lane)
3. **VICE PC-trace diff harness** (unblocks future bugs in 2-min iterations vs 30-min)
4. **$D200-$D3FF I/O hole RAM** (small, high value, sim-testable now)
5. **Doom re-verify** (resolves bug 2.2 ambiguity)
6. **Bank $01 SRAM shadow** (correctness, M10K-constrained, ~3-5 days)
7. **Phase B: write buffer drain + WriteSmart** (performance, ~5-10 days, gated on Asterix/Doom stable)
8. **DOS extension $D0BE/$D0BF** (low priority)
9. **Automated regression suite** (`make regress` on test cores)

---

## 14. Resource Budget (current)

- **ALMs**: ~73% (30,300 / 41,910)
- **M10K blocks**: ~95% (496+ / 553) — sensitivity high; +2 blocks risks fitter failure
- **Async-probe trap**: a single async read in `c64_ram64k.vhd:74` previously
  disabled M10K inference and exploded 64 KB RAM into 524k LUT flops, making
  the design 1120% oversized (`project_bram64k_async_probe_breaks_fit.md`).
  Watch for this when adding probe ports.

This budget constrains:
- Bank $01 SRAM shadow (~16 KB more BRAM)
- Per-byte BRAM valid array (~7 blocks)
- Any cache widening
- Any new dual-port BRAM regions

Mitigation paths: shrink the 8 KB cache, remove unused diagnostic registers, or
use distributed/MLAB RAM for small (<1 KB) regions.

---

## 15. Document Maintenance

This doc is updated each time a meaningful piece of the project's status
changes (new bug found, feature lands, bench added). The "Snapshot date"
header is the source of truth for currency. If you find this doc stale by
more than 2 weeks, refresh it before relying on it for planning.

For currently-running debug context see `docs/session_handoff.md`.
For long-term sequenced work see `docs/roadmap.md`.
For per-incident detail see `~/.claude/projects/.../memory/MEMORY.md`.
