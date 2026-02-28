# Diagnostic ROM MVP Generator

Generate a menu-driven C64 diagnostic KERNAL MVP (8KB at `$E000-$FFFF`).

Related skill docs:
- General MiSTer: [Skill_MiSTer.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer.md)
- C64-specific MiSTer workflow: [Skill_MiSTer_C64.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer_C64.md)

Current MVP menu keys:
- `1` CPU core test
- `2` IRQ timing test
- `3` VIC/screen sanity test
- `4` SuperCPU detect test
- `R` run all

Output status markers:
- `P` pass
- `F` fail
- `S` skip (used when SuperCPU is not detected)

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
