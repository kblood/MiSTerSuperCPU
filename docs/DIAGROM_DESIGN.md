# C64 General Diagnostic ROM Design

## Goal

Create a menu-driven C64 diagnostic ROM framework where SuperCPU diagnostics are one test category among many, not a standalone ROM.

## ROM Product Types

1. `diag_system.rom` (loadable from MiSTer OSD):
- Format: `BASIC + DIAG_KERNAL + 1541`
- Main user-facing diagnostic menu.

2. `scpu64.mif` (compile-time SuperCPU kickstart ROM):
- Optional companion image for low-level SuperCPU startup diagnostics.
- Built by existing ROM builder flow.

## User Experience

Boot directly to a diagnostics menu screen:

- Title and version
- Platform info (PAL/NTSC, CIA mode, SuperCPU on/off if detectable)
- Test groups with hotkeys
- Footer with controls

Example menu:

- `1` CPU Core
- `2` Memory/Buses
- `3` Interrupt/Timing
- `4` VIC-II/Display
- `5` CIA/SID/IO
- `6` Storage/IEC
- `7` SuperCPU
- `8` Full Test Sweep
- `R` Re-run last
- `S` Save/Export summary (optional)

Each group opens a sub-menu with:
- `Run selected`
- `Run all in group`
- `Back`

## Test Framework Architecture

## Core concepts

1. Test case descriptor table (ROM):
- test id
- group id
- name pointer
- flags (quick/long/destructive/requires SuperCPU)
- function pointer

2. Unified test result record (RAM):
- status (`PASS`, `FAIL`, `SKIP`, `WARN`)
- error code
- context bytes (up to N)
- cycle/iteration counters if relevant

3. Scheduler:
- single test
- group sweep
- full sweep
- abort handling (`STOP/RESTORE`)

4. Renderer:
- menu pages
- per-test live status
- summary page with failure drill-down

## Module boundary

- `diag_main`: boot + menu loop
- `diag_ui`: text rendering/input helpers
- `diag_runner`: executes descriptors and writes result records
- `diag_tests_*`: category-specific tests

## Memory/Layout Plan

Suggested baseline:

- ROM space:
  - `$E000-$EFFF`: kernel/menu/framework code
  - `$F000-$FF7F`: test stubs/dispatch/vector helpers
  - `$FF80-$FFFF`: vectors, signatures, traps

- RAM usage:
  - `$0200-$02FF`: framework state + input buffer
  - `$0300-$03FF`: result summary table
  - `$0400+`: screen output
  - scratch ranges reserved per test group

## Test Categories

## 1) CPU Core

- ALU ops, flags, branches
- stack ops / `JSR`/`RTS` / `BRK`/`RTI`
- addressing mode sanity

## 2) Memory/Buses

- ZP / stack page / low RAM march tests
- selected RAM windows (`$0400-$07FF`, `$C000-$CFFF`)
- read/write alias checks

## 3) Interrupt/Timing

- CIA timer IRQ cadence
- IRQ ack correctness
- RTI return integrity
- optional NMI trap behavior

## 4) VIC-II/Display

- badline stress pattern
- screen/code/color consistency checks
- raster interrupt timing smoke test

## 5) CIA/SID/IO

- CIA port direction/readback tests
- TOD/serial basic checks
- SID register write/read behavior where applicable

## 6) Storage/IEC (non-destructive)

- IEC line activity probes
- optional drive present/status checks

## 7) SuperCPU (subset group)

Only enabled when SuperCPU mode detected/configured.

- 65C816 emulation-mode compatibility tests
- bank transition smoke tests
- `$D07A/$D07E` behavior checks
- IRQ/RTI path under SuperCPU timing
- screen-read artifact probes (targeted tests from your current work)

Tests report `SKIP` if SuperCPU is unavailable.

## Result Model

Each test returns:
- status byte
- failure code
- up to 4 context bytes (e.g., expected/actual/address low/high)

Summary screen:
- `PASS x/y`
- failed test ids
- select failure for details (context decode)

## Development Phases

1. Framework MVP
- boot + menu
- descriptor table + runner
- 3-5 baseline CPU tests

2. Core diagnostics
- memory, IRQ/timing, VIC basic

3. SuperCPU group integration
- port existing V22-style checks into modular tests

4. Polish
- persistent summary page
- optional export/log encoding

## Implementation Strategy In This Repo

1. Keep `gen_diag_rom.py` as generator backend initially.
2. Refactor into modules:
- `diag_framework.py` (menu, descriptors, runner codegen)
- `diag_tests_cpu.py`, `diag_tests_irq.py`, `diag_tests_scpu.py`, etc.
3. Emit one assembled binary blob for `DIAG_KERNAL`.
4. Build final loadable `.rom` with `tools/rom_builder`.

## Immediate Next Step

Build a minimal menu-capable MVP with:
- main menu UI
- descriptor table
- 4 tests:
  - CPU immediate/store/load
  - stack push/pop
  - IRQ entry/ack/RTI
  - SuperCPU presence check (`SKIP` if unavailable)

