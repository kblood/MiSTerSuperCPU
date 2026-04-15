#requires -Version 5.1
<#
.SYNOPSIS
    Build and run the PRG-loader GHDL testbench.

.DESCRIPTION
    Analyzes the behavioral DUT + testbench, elaborates, and runs the
    simulation. The bench reproduces the MiSTer SuperCPU PRG-load path
    end-to-end with a behavioral reimplementation of inj_meminit +
    bram_invalidate + a minimal cache stub.

    Deliverables:
      - work/prg_loader_tb.log      full simulation transcript
      - work/prg_loader_tb.fst      FST waveform (pywellen / Surfer)
    Exit code 0 = PASS, nonzero = FAIL (any assertion mismatch).

    This is a GHDL-only bench — no Quartus, no MiSTer hardware.
#>

[CmdletBinding()]
param(
    [string]$StopTime = "2ms"
)

$ErrorActionPreference = 'Stop'

# --- locate GHDL ---
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) {
        throw "ghdl.exe not found. Install GHDL or fix the hard-coded path in run_tb.ps1."
    }
}

# --- paths ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$workDir   = Join-Path $scriptDir 'work'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# --- source list (dependency order: package first, DUT, then testbench) ---
$sources = @(
    (Join-Path $scriptDir 'prg_loader_pkg.vhd'),
    (Join-Path $scriptDir 'prg_loader_dut.vhd'),
    (Join-Path $scriptDir 'prg_loader_tb.vhd')
)

foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "Missing source: $s" }
}

$ghdlFlags = @('--std=08', '--ieee=standard', "--workdir=$workDir")

Push-Location $workDir
try {
    Write-Host "==> Analyze" -ForegroundColor Cyan
    foreach ($s in $sources) {
        Write-Host "    $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }

    Write-Host "==> Elaborate" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags prg_loader_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }

    Write-Host "==> Run (stop-time=$StopTime)" -ForegroundColor Cyan
    $logPath  = Join-Path $workDir 'prg_loader_tb.log'
    $wavePath = Join-Path $workDir 'prg_loader_tb.fst'
    & $ghdl -r @ghdlFlags prg_loader_tb `
        --fst=$wavePath `
        --stop-time=$StopTime `
        --ieee-asserts=disable-at-0 `
        2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE

    Write-Host ""
    Write-Host "log:  $logPath"
    Write-Host "wave: $wavePath"
    if ($rc -eq 0) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
    } else {
        Write-Warning "RESULT: FAIL (ghdl -r exited $rc)"
    }
    exit $rc
} finally {
    Pop-Location
}
