#requires -Version 5.1
# Milestone A Build C extended bench. Complements the baseline
# sdram_pm_lite_tb by exercising the actual RTL changes made in this
# milestone — see sdram_pm_buildc_extended_tb.vhd header for scenario
# list. Runner shape mirrors run_sdram_pm_tb.ps1 so reviewers can
# diff the two side-by-side.
#
# Usage:
#   .\run_sdram_pm_buildc_extended_tb.ps1
#   .\run_sdram_pm_buildc_extended_tb.ps1 -StopTimeNs 50000
[CmdletBinding()]
param(
    [int]$StopTimeNs = 30000
)

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found on PATH; install GHDL or update the absolute path in this script" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$workDir   = Join-Path $scriptDir 'work_extended'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# Source list. lite model is shared with the baseline bench so future
# RTL adjustments to the model are picked up by both. Bench file is
# new to this milestone.
$sources = @(
    (Join-Path $scriptDir 'sdram_pm_lite.vhd'),
    (Join-Path $scriptDir 'sdram_pm_buildc_extended_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

Push-Location $workDir
try {
    foreach ($s in $sources) {
        Write-Host "ghdl -a $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags sdram_pm_buildc_extended_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'sdram_pm_buildc_extended_tb.log'
    Write-Host ""
    Write-Host "Run: STOP=$StopTimeNs ns"
    & $ghdl -r @ghdlFlags sdram_pm_buildc_extended_tb --stop-time="${StopTimeNs}ns" 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"

    $result = Select-String -Path $logPath -Pattern '^RESULT:' | Select-Object -Last 1
    if ($result) {
        Write-Host ""
        Write-Host "Final: $($result.Line)"
        if ($result.Line -match '^RESULT: PASS') {
            exit 0
        } else {
            exit 1
        }
    } else {
        Write-Host "WARNING: no RESULT line found in log" -ForegroundColor Yellow
        exit ($rc)
    }
}
finally {
    Pop-Location
}
