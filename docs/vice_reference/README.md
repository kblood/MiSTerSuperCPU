# VICE reference workspace

This folder organizes how we use the open-source VICE emulator source as a
**behavior oracle** for the MiSTer C64 / SuperCPU Verilator harness.

## Purpose

We are **not** replacing the RTL harness with VICE.
We are using VICE to answer a narrower question faster:

> What is the minimum machine behavior needed to cold-boot to BASIC `READY.`?

That helps us decide how much fidelity the reduced desktop RTL harness needs.

## Layout

- `docs/vice_reference/README.md`
  - overview and workflow
- `docs/vice_reference/source_map.md`
  - important VICE source files and why they matter
- `docs/vice_reference/boot_minimum_subset.md`
  - current working hypothesis for the smallest boot-capable subset
- `tools/sync_vice_reference.sh`
  - clones/updates a local sparse VICE checkout for research

## Local checkout policy

The VICE source checkout is **not** committed into this repo.
Use the sync script to create/update a local sparse checkout under:

- `external/vice-svn-mirror/`

That folder is gitignored on purpose.

## Why VICE is useful here

The current reduced Verilator harness already includes a lot of real MiSTer RTL,
but it still stubs or simplifies key machine pieces. VICE gives us a faster way
to inspect:

- C64 cold-boot init order
- CIA/keyboard expectations
- SuperCPU-specific init order (`xscpu64` / `scpu64`)
- memory power-up responsibilities
- what is likely boot-critical vs optional for first `READY.`

## Initial findings from VICE source

### Normal C64 init order
In `vice/src/c64/c64.c`, VICE initializes in this broad order:
- memory/ROM load
- traps/serial/RS232/printer/tape/datasette/drive/autostart
- VIC-II
- C64 memory init
- CIA1 / CIA2
- keyboard
- sound
- keyboard buffer
- C64 I/O
- glue logic

The important part for our harness is that **VIC, memory, CIAs, and keyboard are
all in place before the machine reaches normal runtime**.

### SuperCPU init order
In `vice/src/scpu64/scpu64.c`, VICE does the analogous sequence:
- load memory/ROMs
- init VIC-II
- init SCPU memory
- init CIA1 / CIA2
- init keyboard
- later init glue logic / IEC / cartridge

This strongly suggests the **boot-capable subset** for our harness should focus
first on:
- memory
- VIC-visible behavior
- CIA behavior
- keyboard defaults / matrix behavior

### Reset / power-up split
VICE separates reset from power-up in `scpu64.c`:
- `machine_specific_reset()` resets CIA, SID, VIC-II, cartridge, drives, etc.
- `machine_specific_powerup()` does cartridge powerup, VIC-II register reset,
  userport/joyport powerup

This is a useful reminder that our reduced harness must not assume reset and
power-up are interchangeable.

## Suggested workflow

1. `bash tools/sync_vice_reference.sh`
2. read relevant VICE files listed in `source_map.md`
3. update `boot_minimum_subset.md` when we learn something useful
4. only then change the RTL harness

## Immediate next use

Use VICE source to answer:
- Do we need real CIA timers for first `READY.`?
- Is a stateful port/DDRx model enough for cold boot?
- Which keyboard/CIA interactions are required before BASIC appears?
- Which subsystems are clearly *not* required for first `READY.`?
