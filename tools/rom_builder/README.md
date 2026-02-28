# ROM Builder Tool

This folder contains a small ROM build toolchain for MiSTer C64/SuperCPU work.

Skill docs:
- General MiSTer: [Skill_MiSTer.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer.md)
- C64-specific MiSTer workflow: [Skill_MiSTer_C64.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer_C64.md)

It supports:
- Building a loadable C64 system ROM (`BASIC + KERNAL + 1541`) for OSD loading.
- Building a SuperCPU kickstart `.mif` image from a raw binary.
- Building one or more outputs from a JSON manifest.

## Why this lives in the main repo

This tool is intentionally kept in the main repository (not a separate git repo):
- It needs direct access to core paths (`C64_MiSTer/rtl/roms/...`).
- It should evolve alongside debug workflow changes.
- It avoids submodule/tool version drift while debugging.

## Quick start

1. Copy and edit one of the sample manifests in `profiles/`.
2. Run:

```powershell
Set-Location C:\LLM\C64\MiSTerSuperCPU
.\tools\rom_builder\build_roms.ps1 -Manifest .\tools\rom_builder\profiles\debug_template.json
```

3. Upload to MiSTer:

```powershell
.\tools\rom_builder\deploy_to_mister.ps1 `
  -LocalFile .\tools\rom_builder\out\debug_system.rom `
  -RemotePath '/media/usb0/Games/C64/C64 Kernals/debug_system.rom'
```

Or use the wrapper (build ROM artifacts, upload debug ROM, copy prebuilt core):

```powershell
.\tools\rom_builder\build_and_deploy_debug.ps1
```

## Direct modes

### Build loadable C64 ROM pack

```powershell
.\tools\rom_builder\build_roms.ps1 -Mode system `
  -Basic .\rom_inputs\basic.bin `
  -Kernal .\rom_inputs\debug_kernal.bin `
  -Drive1541 .\rom_inputs\dos1541.bin `
  -Out .\tools\rom_builder\out\debug_system.rom
```

Expected output size:
- 32768 bytes (8K BASIC + 8K KERNAL + 16K 1541), or
- 49152 bytes (8K BASIC + 8K KERNAL + 32K 1541)

### Build SuperCPU MIF from binary

```powershell
.\tools\rom_builder\build_roms.ps1 -Mode scpu `
  -InputBin .\rom_inputs\scpu_kick.bin `
  -OutMif .\C64_MiSTer\rtl\roms\scpu64.mif `
  -Depth 65536
```

Notes:
- Input binary must be `<= Depth` bytes.
- Remaining bytes are padded with `FF`.
- Default depth is `65536`, matching current `scpu64.mif`.

## Manifest format

```json
{
  "system_roms": [
    {
      "name": "debug_system",
      "basic": "rom_inputs/basic.bin",
      "kernal": "rom_inputs/debug_kernal.bin",
      "drive1541": "rom_inputs/dos1541.bin",
      "output": "tools/rom_builder/out/debug_system.rom"
    }
  ],
  "supercpu_mifs": [
    {
      "name": "scpu_kick_debug",
      "input_bin": "rom_inputs/scpu_kick.bin",
      "output_mif": "C64_MiSTer/rtl/roms/scpu64.mif",
      "depth": 65536,
      "fill_byte_hex": "FF"
    }
  ]
}
```

Paths may be absolute or repo-relative.

## Prewired local profile

`profiles/debug_local.json` is wired to expected local inputs in `tools/rom_builder/rom_inputs/`:
- `basic.bin` (8K)
- `debug_kernal.bin` (8K)
- `dos1541.bin` (16K or 32K)
- `scpu_kick.bin` (up to 64K by default)

You can run it directly:

```powershell
.\tools\rom_builder\build_roms.ps1 -Mode manifest -Manifest .\tools\rom_builder\profiles\debug_local.json
```

Then upload output(s):

```powershell
.\tools\rom_builder\deploy_to_mister.ps1 `
  -LocalFile .\tools\rom_builder\out\debug_system.rom `
  -RemotePath '/media/usb0/Games/C64/C64 Kernals/debug_system.rom'
```
