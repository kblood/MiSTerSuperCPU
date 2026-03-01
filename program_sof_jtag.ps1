# program_sof_jtag.ps1
# Programs the latest C64 .sof over USB-Blaster (DE10-Nano JTAG).
#
# Usage:
#   .\program_sof_jtag.ps1
#   .\program_sof_jtag.ps1 -SofPath C:\path\to\C64.sof

param(
    [string]$QBin = "C:\intelFPGA_lite\17.0\quartus\bin64",
    [string]$SofPath = "C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.sof",
    [string]$Cable = "DE-SoC [USB-1]",
    [int]$DeviceIndex = 2
)

$jtagconfig = Join-Path $QBin "jtagconfig.exe"
$quartusPgm = Join-Path $QBin "quartus_pgm.exe"

if (-not (Test-Path $jtagconfig)) {
    Write-Error "Missing jtagconfig.exe at '$jtagconfig'"
    exit 1
}
if (-not (Test-Path $quartusPgm)) {
    Write-Error "Missing quartus_pgm.exe at '$quartusPgm'"
    exit 1
}
if (-not (Test-Path $SofPath)) {
    Write-Error "SOF file not found: '$SofPath'"
    exit 1
}

Write-Host "JTAG chain:" -ForegroundColor Cyan
& $jtagconfig

Write-Host "Programming '$SofPath' on cable '$Cable' device @$DeviceIndex..." -ForegroundColor Cyan
& $quartusPgm -c $Cable -m jtag -o "p;$SofPath@$DeviceIndex"

if ($LASTEXITCODE -ne 0) {
    Write-Error "quartus_pgm failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "Programming completed." -ForegroundColor Green
