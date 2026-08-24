#requires -Version 5.1
# CONTROL variant runner for p65c816_inc_beq_ce_stall_ctrl_tb.vhd
# Same harness as the CE-stall test but STALL_START is pushed out of
# range so CE never actually drops. Isolates whether the 256->257
# write-count discrepancy seen in the stalled runs is caused by the
# stall itself or is a harness/accounting artifact.
[CmdletBinding()]
param(
    [string]$StopTime = "10ms"
)

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl\65C816'
$workDir   = Join-Path $scriptDir 'work_cestall_ctrl'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'P65816_pkg.vhd'),
    (Join-Path $rtl 'BCDAdder.vhd'),
    (Join-Path $rtl 'AddSubBCD.vhd'),
    (Join-Path $rtl 'ALU.vhd'),
    (Join-Path $rtl 'AddrGen.vhd'),
    (Join-Path $rtl 'MCode.vhd'),
    (Join-Path $rtl 'P65C816.vhd'),
    (Join-Path $scriptDir 'p65c816_inc_beq_ce_stall_ctrl_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags p65c816_inc_beq_ce_stall_ctrl_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'inc_beq_ce_stall_ctrl.log'
    & $ghdl -r @ghdlFlags p65c816_inc_beq_ce_stall_ctrl_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"
    if ($rc -ne 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
