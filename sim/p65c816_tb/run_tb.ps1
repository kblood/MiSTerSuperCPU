#requires -Version 5.1
<#
.SYNOPSIS
    Build and run the P65C816 LDA-long GHDL testbench.

.DESCRIPTION
    Analyzes the bare 65C816 core sources + the testbench, elaborates,
    and runs the simulation. Output is a per-cycle trace log on stdout
    and a GHW waveform under sim/p65c816_tb/work/lda_long.ghw.

    No Intel megafunctions or vendor stubs are required — the 65C816
    core uses only ieee.std_logic_1164 / ieee.numeric_std / work.P65816_pkg.
#>

[CmdletBinding()]
param(
    [string]$LogFile = "lda_long.log",
    [string]$WaveFile = "lda_long.ghw",
    [string]$StopTime = "5ms"
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

# --- repo root (script lives at sim/p65c816_tb/run_tb.ps1) ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl\65C816'
$workDir   = Join-Path $scriptDir 'work'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# --- source list (dependency order: package first, then leaf, then top) ---
$sources = @(
    (Join-Path $rtl 'P65816_pkg.vhd'),
    (Join-Path $rtl 'BCDAdder.vhd'),
    (Join-Path $rtl 'AddSubBCD.vhd'),
    (Join-Path $rtl 'ALU.vhd'),
    (Join-Path $rtl 'AddrGen.vhd'),
    (Join-Path $rtl 'MCode.vhd'),
    (Join-Path $rtl 'P65C816.vhd'),
    (Join-Path $repoRoot 'C64_MiSTer\rtl\cpu_65c816.vhd'),
    (Join-Path $scriptDir 'p65c816_lda_long_tb.vhd'),
    (Join-Path $scriptDir 'cpu_65c816_lda_long_tb.vhd'),
    (Join-Path $scriptDir 'p65c816_rep_tb.vhd'),
    (Join-Path $scriptDir 'p65c816_native_switch_tb.vhd'),
    (Join-Path $scriptDir 'cpu_65c816_native_switch_tb.vhd'),
    (Join-Path $scriptDir 'p65c816_xflag_bank_transition_tb.vhd')
)

foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "Missing source: $s" }
}

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

Push-Location $workDir
try {
    Write-Host "==> Analyze" -ForegroundColor Cyan
    foreach ($s in $sources) {
        Write-Host "    $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }

    Write-Host "==> Elaborate (bare-core bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags p65c816_lda_long_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (bare core) failed" }

    Write-Host "==> Elaborate (wrapper bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags cpu_65c816_lda_long_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (wrapper) failed" }

    Write-Host "==> Elaborate (REP bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags p65c816_rep_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (REP bench) failed" }

    Write-Host "==> Elaborate (native-switch bare bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags p65c816_native_switch_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (native-switch bare bench) failed" }

    Write-Host "==> Elaborate (native-switch wrapper bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags cpu_65c816_native_switch_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (native-switch wrapper bench) failed" }

    Write-Host "==> Elaborate (xflag bank-transition bench)" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags p65c816_xflag_bank_transition_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e (xflag bank-transition bench) failed" }

    Write-Host "==> Run bare-core bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $bareLogPath  = Join-Path $workDir $LogFile
    $bareWavePath = Join-Path $workDir $WaveFile
    & $ghdl -r @ghdlFlags p65c816_lda_long_tb `
        --wave=$bareWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $bareLogPath
    $rcBare = $LASTEXITCODE
    if ($rcBare -ne 0) {
        Write-Warning "bare-core ghdl -r exited $rcBare"
    }

    Write-Host "==> Run wrapper bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $wrapLogPath  = Join-Path $workDir 'lda_long_wrapper.log'
    $wrapWavePath = Join-Path $workDir 'lda_long_wrapper.ghw'
    & $ghdl -r @ghdlFlags cpu_65c816_lda_long_tb `
        --wave=$wrapWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $wrapLogPath
    $rcWrap = $LASTEXITCODE
    if ($rcWrap -ne 0) {
        Write-Warning "wrapper ghdl -r exited $rcWrap"
    }

    Write-Host "==> Run REP bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $repLogPath  = Join-Path $workDir 'rep.log'
    $repWavePath = Join-Path $workDir 'rep.ghw'
    & $ghdl -r @ghdlFlags p65c816_rep_tb `
        --wave=$repWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $repLogPath
    $rcRep = $LASTEXITCODE
    if ($rcRep -ne 0) {
        Write-Warning "REP ghdl -r exited $rcRep"
    }

    Write-Host "==> Run native-switch bare bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $nsBareLogPath  = Join-Path $workDir 'native_switch.log'
    $nsBareWavePath = Join-Path $workDir 'native_switch.ghw'
    & $ghdl -r @ghdlFlags p65c816_native_switch_tb `
        --wave=$nsBareWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $nsBareLogPath
    $rcNsBare = $LASTEXITCODE
    if ($rcNsBare -ne 0) {
        Write-Warning "native-switch bare ghdl -r exited $rcNsBare"
    }

    Write-Host "==> Run native-switch wrapper bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $nsWrapLogPath  = Join-Path $workDir 'native_switch_wrapper.log'
    $nsWrapWavePath = Join-Path $workDir 'native_switch_wrapper.ghw'
    & $ghdl -r @ghdlFlags cpu_65c816_native_switch_tb `
        --wave=$nsWrapWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $nsWrapLogPath
    $rcNsWrap = $LASTEXITCODE
    if ($rcNsWrap -ne 0) {
        Write-Warning "native-switch wrapper ghdl -r exited $rcNsWrap"
    }

    Write-Host "==> Run xflag bank-transition bench (stop-time=$StopTime)" -ForegroundColor Cyan
    $xfLogPath  = Join-Path $workDir 'xflag_bank_transition.log'
    $xfWavePath = Join-Path $workDir 'xflag_bank_transition.ghw'
    & $ghdl -r @ghdlFlags p65c816_xflag_bank_transition_tb `
        --wave=$xfWavePath `
        --stop-time=$StopTime `
        2>&1 | Tee-Object -FilePath $xfLogPath
    $rcXflag = $LASTEXITCODE
    if ($rcXflag -ne 0) {
        Write-Warning "xflag bank-transition ghdl -r exited $rcXflag"
    }

    Write-Host ""
    Write-Host "bare-core log:           $bareLogPath"
    Write-Host "bare-core wave:          $bareWavePath"
    Write-Host "wrapper log:             $wrapLogPath"
    Write-Host "wrapper wave:            $wrapWavePath"
    Write-Host "REP log:                 $repLogPath"
    Write-Host "REP wave:                $repWavePath"
    Write-Host "native-switch bare log:  $nsBareLogPath"
    Write-Host "native-switch bare wave: $nsBareWavePath"
    Write-Host "native-switch wrap log:  $nsWrapLogPath"
    Write-Host "native-switch wrap wave: $nsWrapWavePath"
    Write-Host "xflag log:               $xfLogPath"
    Write-Host "xflag wave:              $xfWavePath"
    if ($rcBare -ne 0 -or $rcWrap -ne 0 -or $rcRep -ne 0 -or $rcNsBare -ne 0 -or $rcNsWrap -ne 0 -or $rcXflag -ne 0) { exit 1 } else { exit 0 }
} finally {
    Pop-Location
}
