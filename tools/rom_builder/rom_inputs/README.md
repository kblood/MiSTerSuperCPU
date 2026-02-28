# ROM Input Staging

Put your local ROM binaries here for the prewired profile:

- `basic.bin` (8192 bytes)
- `debug_kernal.bin` (8192 bytes)
- `dos1541.bin` (16384 or 32768 bytes)
- `scpu_kick.bin` (up to 65536 bytes by default profile)

Then run:

```powershell
Set-Location C:\LLM\C64\MiSTerSuperCPU
.\tools\rom_builder\build_roms.ps1 -Mode manifest -Manifest .\tools\rom_builder\profiles\debug_local.json
```

