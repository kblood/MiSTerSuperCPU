#requires -Version 5.1
# Milestone B / Option H (2026-05-25): cpu_65c816 + scpu_async_bridge + mock
# arbiter + real mos6526 + LIVE IRQ delivery. Drops SEI; wires cia_irq_n into
# the CPU; configures Timer A for periodic underflow. Tests whether the
# IRQ-vector-fetch micro-sequence races with the bridge's bus_di_capture /
# WAIT_ACK release.
#
# Usage:
#   .\run_cpu_cia_irq_tb.ps1                  # MCP, RATIO=2 (default)
#   .\run_cpu_cia_irq_tb.ps1 -Passthrough     # passthrough regression net
#   .\run_cpu_cia_irq_tb.ps1 -Ratio 1         # matched-clock MCP
[CmdletBinding()]
param(
    [int]$StopTimeNs = 500000,
    [int]$Ratio      = 2,
    [switch]$Passthrough
)

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
# The worktree this script lives in is on an older branch base (pre-MCP-bridge);
# pull RTL from the main project worktree which has the current bridge source.
# Override with -RtlRoot if needed.
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$mainRtl   = 'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl'
$localRtl  = Join-Path $repoRoot 'C64_MiSTer\rtl'
if (Test-Path (Join-Path $localRtl 'scpu_async_bridge.vhd')) {
    $rtl = $localRtl
} else {
    $rtl = $mainRtl
    Write-Host "Note: using RTL from main worktree at $rtl (this worktree's branch predates the MCP bridge)."
}
$cpu       = Join-Path $rtl '65C816'
$workDir   = Join-Path $scriptDir 'work_cia_irq'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $cpu 'P65816_pkg.vhd'),
    (Join-Path $cpu 'BCDAdder.vhd'),
    (Join-Path $cpu 'AddSubBCD.vhd'),
    (Join-Path $cpu 'ALU.vhd'),
    (Join-Path $cpu 'AddrGen.vhd'),
    (Join-Path $cpu 'MCode.vhd'),
    (Join-Path $cpu 'P65C816.vhd'),
    (Join-Path $rtl 'cpu_65c816.vhd'),
    (Join-Path $rtl 'scpu_async_bridge.vhd'),
    (Join-Path $scriptDir 'mos6526_lite.vhd'),
    (Join-Path $scriptDir 'cpu_cia_irq_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        Write-Host "ghdl -a $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_cia_irq_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $passVal = if ($Passthrough) { 1 } else { 0 }
    $tag     = if ($Passthrough) { 'PT' } else { 'MCP' }
    $genericArgs = @(
        "-gRATIO=$Ratio",
        "-gPASSTHROUGH_MODE=$passVal",
        "-gSTOP_TIME_NS=$StopTimeNs"
    )
    $logPath = Join-Path $workDir "cpu_cia_irq_tb_R${Ratio}_${tag}.log"
    Write-Host ""
    Write-Host "Run: RATIO=$Ratio MODE=$tag STOP=$StopTimeNs"
    & $ghdl -r @ghdlFlags cpu_cia_irq_tb @genericArgs 2>&1 | Tee-Object -FilePath $logPath
    Write-Host ""
    Write-Host "log: $logPath"
}
finally {
    Pop-Location
}
