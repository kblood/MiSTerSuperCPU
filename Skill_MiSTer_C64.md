# MiSTer C64 Skill

C64-core-specific operational notes for this repository.

## Scope

Use this skill for:
- C64 core deploy/debug loops
- C64 ROM pack creation/loading
- SuperCPU ROM (`scpu64.mif`) update flow
- C64-specific MiSTer filesystem paths

For generic MiSTer access details, see [Skill_MiSTer.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer.md).

## Verified C64 Paths on This MiSTer

- C64 ROM folder:
  - `/media/usb0/Games/C64/C64 Kernals`
  - Note: folder name contains a space.
- C64 test core deploy path:
  - `/media/fat/_Test/C64.rbf`

## C64 Core Deploy

```powershell
scp .\C64_MiSTer\output_files\C64.rbf root@192.168.50.130:/media/fat/_Test/C64.rbf
```

## C64 ROM Builder Workflow

Tooling is in:
- `tools/rom_builder/`

Primary files:
- `tools/rom_builder/build_roms.ps1`
- `tools/rom_builder/build_and_deploy_debug.ps1`
- `tools/rom_builder/deploy_to_mister.ps1`
- `tools/rom_builder/profiles/debug_local.json`

### Input staging

Place source binaries in:
- `tools/rom_builder/rom_inputs/basic.bin` (8K)
- `tools/rom_builder/rom_inputs/debug_kernal.bin` (8K)
- `tools/rom_builder/rom_inputs/dos1541.bin` (16K/32K)
- `tools/rom_builder/rom_inputs/scpu_kick.bin` (<=64K default)

### Build + upload debug ROM (and optional core copy)

```powershell
Set-Location C:\LLM\C64\MiSTerSuperCPU
.\tools\rom_builder\build_and_deploy_debug.ps1
```

Skip copying core `.rbf`:

```powershell
.\tools\rom_builder\build_and_deploy_debug.ps1 -CopyCore $false
```

## Diagnostic KERNAL MVP Workflow

Generator:
- `tools/diagrom/gen_diag_kernal_mvp.py`

Generate/update `debug_kernal.bin`:

```powershell
python .\tools\diagrom\gen_diag_kernal_mvp.py
```

Then rebuild/upload via wrapper:

```powershell
.\tools\rom_builder\build_and_deploy_debug.ps1 -CopyCore $false
```

## Current SuperCPU Artifact Context

- Read-side VIC capture has been validated in RTL instrumentation.
- Debug ROM variants can still exhibit scrolling-line behavior while earlier V22 diagnostic ROM did not.
- Keep test ROM identity explicit (visible marker/banner) during comparisons.

