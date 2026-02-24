# program_fpga.ps1 - Program MiSTer FPGA directly via USB Blaster
param([string]$SofFile = "C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.sof")

$q = "C:\altera_standard\25.1std\quartus\bin64\quartus_pgm.exe"
if (-not (Test-Path $SofFile)) { Write-Error "Not found: $SofFile"; exit 1 }
$info = Get-Item $SofFile
Write-Host "Programming: $($info.Name) ($([math]::Round($info.Length/1MB,1)) MB, built $($info.LastWriteTime))"
& $q -c "DE-SoC [USB-1]" -m JTAG -o "p;$SofFile@2" 2>&1 | Where-Object { $_ -match "Error|Warning|success|configured|Ended" }
