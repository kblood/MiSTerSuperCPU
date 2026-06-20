# C64U/ — Commodore 64 Ultimate (U64) port exploration

This folder is for all research, planning, and code related to the
**potential pivot** of our SuperCPU work from MiSTer to the C64 Ultimate
(Gideon Zweijtzer's hardware).

## Status

**Investigation closed; pivoted to a knowledge-transfer handoff.** The original
"fork the U64 ourselves" plan is **blocked** — the U64 (mk1) / U64-II FPGA
bitstream is **not** open source (only NiosII / RISC-V firmware is; see
`docs/03_repo_inventory.md`). We have no CPU integration point to swap into.

**New deliverable: `for-gideon/`** — a self-contained package for Gideon
Zweijtzer (the U64 author, who *does* have the bitstream sources) documenting
everything we discovered while adding 65C816 SuperCPU support to the MiSTer C64
core, plus the reusable RTL (65C816 core), the SuperCPU ROM, the register/memory
model, the VICE-differential test methodology, and — most importantly — the
timing autopsy showing the ~4 MHz wall is a MiSTer-FPGA property his platform is
positioned to walk through. **Start at `for-gideon/README.md`.**

Earlier investigation pre-conditions (now superseded by the handoff):
1. v343 MiSTer bootmap retry — Doom/Wolf3D since validated on later RBFs.
2. U64 host core buildable from source — **NO** (bitstream closed; firmware-only repo).
3. U64 turbo accelerates 65C816 throughput — open; a question for Gideon (the
   handoff frames why it very likely can).

## Folder layout

- `for-gideon/` — **the deliverable.** Self-contained handoff package (docs +
  reusable RTL + SuperCPU ROM). See `for-gideon/README.md`.
- `docs/` — our internal investigation notes (why we looked at U64, what
  transfers, the bitstream-openness blocker).
  - `01_overview.md` — why a pivot was considered
  - `02_transfer_inventory.md` — what carries over from MiSTer work
  - `03_repo_inventory.md` — U64 repo openness assessment (BLOCKER found)
  - `04_porting_plan_template.md` — staged plan template
- `repos/` — cloned upstream U64 source repos (do not commit; gitignored)
- `scratch/` — experiments, prototype HDL, throwaway code

## Main project status (for context)

- Main project: `C:\LLM\C64\MiSTerSuperCPU\` — MiSTer SuperCPU fork.
- v342 RBF (`71722b93a461fc29562f85836ec31bf1`): Doom renders id credits.
- v343 RBF (in flight as of 2026-05-15): bootmap='1' retry for wolf3d.
- Branch: `vanilla-cpu-swap`.
- Regression: Lorenz t65/SCPU both pass on v342.

## Hardware we own

- MiSTer (DE10-Nano) at `192.168.50.130` — primary dev target so far.
- Ultimate 64 at `192.168.50.94` — production U64. REST API at
  `http://192.168.50.94/v1`. See `docs/ultimate64_agent.md` in main
  project for API usage.

## Cross-cutting docs (in main project, relevant here too)

- `docs/architecture_diagrams.md` — Mermaid diagrams of all core variants
  including planned target.
- `docs/ultimate64_agent.md` — REST API reference.
- `docs/supercpu_feature_status.md` — feature status / regression test plan.
- `docs/debug_methodology.md` — bug-classification methodology.
