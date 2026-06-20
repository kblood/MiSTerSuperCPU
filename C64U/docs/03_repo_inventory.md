---
title: U64 repo inventory — bitstream openness assessment
date: 2026-05-15
status: BLOCKER FOUND
---

# U64 repo inventory

Investigation of `C64U/repos/1541ultimate/` (GideonZ/1541ultimate, GPL-3.0,
shallow-cloned 2026-05-15) to determine whether the U64 FPGA bitstream can
be built from source.

## Verdict

**The U64 (Ultimate 64, mk1) FPGA bitstream is NOT in this repo.** Only
NiosII firmware sources are open. Same for U64-II (RISC-V firmware only).

## Evidence

### 1. Makefile targets named `u64*` build firmware, not bitstream

`Makefile:254-265` — the `u64:` target runs:
- `software/nios_solo_bsp` (NiosII BSP)
- `software/nios_appl_bsp`
- `target/libs/nios2/lwip`
- `target/u64/nios2/ultimate`
- `target/u64/nios2/updater`

Final output: `update.u64` — an application binary loaded by an existing
bitstream's NiosII soft-CPU. Not a `.sof` / `.pof`.

`u64ii:` (Makefile:284-303) is identical structure for U64-II: RISC-V
firmware artifacts (`ultimate.app`, `update.app` → `update.ue2`). No
bitstream emitted.

### 2. `target/fpga/` has no `u64` subdir

Available FPGA targets under `target/fpga/`:
```
u2plus_ecp5    u2p_carttester    u2p_memtest    u2p_riscv    u2pl_slot_tester
mb700          mb700dd           mb700gm        ecp5_dut     ecp5_tester
rv700_loader   rv700au           rv700dd        testdut      testexec
ultimate_logic*.inc files
```
These cover U2, U2+, and various dev/test boards. **No `u64` or `u64ii`
folder exists.**

### 3. README confirms Quartus is for "Nios-II compiler only"

`README.md` of repo states the toolchain expectation for U64 is "Altera
Quartus (tested with 18.1 Lite Edition) - for the Nios-II compiler only".
This is the smoking gun — Quartus is used to invoke the `nios2-elf-gcc`
toolchain bundled with it, not to compile the FPGA fabric.

### 4. No VIC-II VHDL in the repo

A grep for VIC-II equivalents (`video_vicII`, `vic_ii`, `vicii`) inside
the HDL trees returns nothing C64-related — VIC-II lives only in the
closed bitstream blob.

## What we'd actually get if we built the open parts

- NiosII firmware (`update.u64`): file browser, REST API, USB stack,
  cartridge emulation logic that runs on the soft-CPU **inside** the
  closed bitstream.
- That gives us scriptable deploy/screenshot capability (we already
  have this via `docs/ultimate64_agent.md` REST API).
- It does **not** give us any path to swap in a 65C816 — the 6510 lives
  in the closed bitstream and there's no replaceable CPU integration
  point in the open sources.

## Implications for the pivot decision

This is a **hard blocker** for the U64 pivot as originally scoped.
Without bitstream sources we cannot:
- Swap CPU cores.
- Add the `$D07x` / `$D0Bx` SCPU register decode.
- Add SuperRAM bank addressing.
- Touch turbo-mode timing.

The U64 hardware remains useful only as:
- A reference target for differential testing (REST API screenshots
  vs MiSTer screenshots, given identical software).
- A faster vanilla C64 host (the built-in turbo runs vanilla 6510
  code fast, no SCPU support).

## Alternative U64-adjacent paths

1. **spiffycrew/Spiffy_Ultimate** — community fork. Worth checking
   whether they reverse-engineered or open-sourced the bitstream.
   (Not yet inspected.)
2. **U64-II Special Edition** — Gideon released a "Limited Edition"
   that he hinted may eventually be more open. Status unconfirmed.
3. **Ask Gideon directly** — he's been responsive on the forums about
   the open/closed boundary. Could clarify whether bitstream sources
   are licenseable for non-commercial fork work.

## Recommendation

Default back to MiSTer. The v343 retry (bootmap='1' at reset) made
measurable progress on Wolf3D — screen now goes black (DEN=0, indicating
Wolf3D took control of VIC) instead of staying in BASIC textmode, and
PC range widened. Implementing the full SCPU bootmap + kickstart path
on MiSTer is bounded work; pivoting to U64 is blocked without bitstream
sources.

Only revisit U64 if (a) spiffycrew or another fork has the bitstream
open, OR (b) MiSTer kickstart turns out to be irrecoverable for
fundamental architecture reasons (very unlikely given v343 progress).
