#requires -Version 5.1
<#
.SYNOPSIS
    Build and run the Milestone C arbiter sketch bench (GHDL).

.DESCRIPTION
    Analyses arbiter_demand_stub.vhd + arbiter_demand_tb.vhd, elaborates,
    runs. Self-checking testbench — exit 0 = PASS, non-zero = FAIL.

    Companion file: docs/milestone_c_arbiter_design.md (Section G.1
    defines the scenarios this bench covers).
#>

[CmdletBinding()]
param(
    [string]$StopTime = "10us"
)

$ErrorActionPreference = 'Stop'

# --- locate GHDL ---
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) {
        throw "ghdl.exe not found. Install GHDL or fix the hard-coded path."
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$workDir   = Join-Path $scriptDir 'work'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# Compile order: entity first, then bench.
$sources = @(
    (Join-Path $scriptDir 'arbiter_demand_stub.vhd'),
    (Join-Path $scriptDir 'arbiter_demand_tb.vhd')
)

foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "Missing source: $s" }
}

# Standard project GHDL flags (per memory/reference_ghdl_bench_gotchas.md §6).
$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

Push-Location $workDir
try {
    Write-Host "==> Analyze" -ForegroundColor Cyan
    foreach ($s in $sources) {
        Write-Host "    $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }

    Write-Host "==> Elaborate" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags arbiter_demand_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }

    Write-Host "==> Run (stop-time=$StopTime)" -ForegroundColor Cyan
    $logPath = Join-Path $workDir 'arbiter_demand_tb.log'
    & $ghdl -r @ghdlFlags arbiter_demand_tb `
        --stop-time=$StopTime `
        --ieee-asserts=disable-at-0 `
        2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE

    Write-Host ""
    Write-Host "log: $logPath"
    if ($rc -eq 0) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
    } else {
        Write-Warning "RESULT: FAIL (ghdl -r exited $rc)"
    }
    exit $rc
} finally {
    Pop-Location
}
