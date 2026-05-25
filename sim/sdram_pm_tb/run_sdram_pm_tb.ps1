#requires -Version 5.1
# Milestone A sim bench: exercises the proposed Build C HIT/MISS sdram_pm
# controller via sdram_pm_lite.vhd + sdram_pm_lite_tb.vhd. See
# docs/milestone_a_buildc_design.md §6 for scenarios and exit criteria.
#
# Usage:
#   .\run_sdram_pm_tb.ps1                 # default stop-time
#   .\run_sdram_pm_tb.ps1 -StopTimeNs 50000
[CmdletBinding()]
param(
    [int]$StopTimeNs = 20000
)

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found on PATH; install GHDL or update the absolute path in this script" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$workDir   = Join-Path $scriptDir 'work'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# Source list — small, all VHDL, no dependency on the project RTL.
$sources = @(
    (Join-Path $scriptDir 'sdram_pm_lite.vhd'),
    (Join-Path $scriptDir 'sdram_pm_lite_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

Push-Location $workDir
try {
    foreach ($s in $sources) {
        Write-Host "ghdl -a $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags sdram_pm_lite_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'sdram_pm_lite_tb.log'
    Write-Host ""
    Write-Host "Run: STOP=$StopTimeNs ns"
    & $ghdl -r @ghdlFlags sdram_pm_lite_tb --stop-time="${StopTimeNs}ns" 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"

    # Look for RESULT: PASS / RESULT: FAIL line for caller convenience.
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
