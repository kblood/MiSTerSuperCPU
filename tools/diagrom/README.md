# Diagnostic ROM MVP Generator

Generate a menu-driven C64 diagnostic KERNAL MVP (8KB at `$E000-$FFFF`).

Related skill docs:
- General MiSTer: [Skill_MiSTer.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer.md)
- C64-specific MiSTer workflow: [Skill_MiSTer_C64.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer_C64.md)

Menu keys:
- `1` CPU core page
- `2` IRQ timing page
- `3` VIC/screen page
- `4` RAM diagnostics page
- `5` SuperCPU debug page
- `R` run full suite from menu

Per-page controls:
- `R` run the current page test
- `M` return to main menu

Output status markers:
- `P` pass
- `F` fail
- `S` skip (used when SuperCPU is not detected)

RAM diagnostics now include:
- Region probes (base RAM, high RAM, color RAM)
- 16 x 4KB sector probes (mapped-RAM amount sanity)
- CIA timer-based RAM speed index
- REU probe at `$DFxx` (register response + stickiness)
- GeoRAM probe using `$DFFE/$DFFF` bank select and `$DExx` banked data

SuperCPU debug page shows raw register bytes:
- `$D0B2`, `$D07A`, `$D07E`
- Last RAM sector-pass and RAM speed index values for correlation
- Last REU/GeoRAM probe status (`P/F/S`) for correlation

## Generate KERNAL

```powershell
Set-Location C:\LLM\C64\MiSTerSuperCPU
python .\tools\diagrom\gen_diag_kernal_mvp.py
```

Default output:
- `tools/rom_builder/rom_inputs/debug_kernal.bin`

## Build + Deploy with existing wrapper

```powershell
.\tools\rom_builder\build_and_deploy_debug.ps1 -CopyCore $false
```

## Generate SuperCPU Diagnostic Kick ROM (V22)

This produces both:
- `tools/rom_builder/rom_inputs/scpu_kick.bin` (raw 64KB image)
- `C64_MiSTer/rtl/roms/scpu64.mif` (core memory init image)

```powershell
Set-Location C:\LLM\C64\MiSTerSuperCPU
python .\gen_diag_rom.py
```

This keeps `rom_inputs/debug_kernal.bin` unchanged and writes V22 KERNAL separately:
- `tools/rom_builder/rom_inputs/debug_kernal_v22.bin`
- `C64_MiSTer/rtl/roms/scpu64.mif` is also left unchanged by default.

If you explicitly want to overwrite `scpu64.mif` from V22 output:

```powershell
python .\gen_diag_rom.py --update-scpu-mif
```

Build a separate loadable V22 system ROM (without replacing your main debug ROM):

```powershell
.\tools\rom_builder\build_roms.ps1 -Mode manifest `
  -Manifest .\tools\rom_builder\profiles\debug_v22.json
```

Output:
- `tools/rom_builder/out/debug_system_v22.rom`

Deploy V22 separately (example):

```powershell
.\tools\rom_builder\deploy_to_mister.ps1 `
  -LocalFile .\tools\rom_builder\out\debug_system_v22.rom `
  -RemotePath '/media/usb0/Games/C64/C64 Kernals/debug_system_v22.rom'
```

If you want to rebuild `scpu64.mif` from `scpu_kick.bin` via the ROM builder:

```powershell
.\tools\rom_builder\build_roms.ps1 -Mode scpu `
  -InputBin .\tools\rom_builder\rom_inputs\scpu_kick.bin `
  -OutMif .\C64_MiSTer\rtl\roms\scpu64.mif `
  -Depth 65536
```
