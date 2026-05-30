#requires -Version 5.1
# Milestone B SuperRAM bench: real cpu_65c816 inside active scpu_async_bridge,
# native-mode long store/load into bank $02 (SuperRAM) with variable-latency ack.
[CmdletBinding()]
param(
    [int]$StopTimeNs = 50000,
    [int]$Ratio = 2
)

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$cpu       = Join-Path $rtl '65C816'
$workDir   = Join-Path $scriptDir 'work_superram'
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
    (Join-Path $scriptDir 'cpu_in_bridge_superram_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_in_bridge_superram_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $genericArgs = @("-gRATIO=$Ratio", "-gSTOP_TIME_NS=$StopTimeNs")
    $logPath = Join-Path $workDir "cpu_in_bridge_superram_tb_R${Ratio}.log"
    Write-Host "Run: RATIO=$Ratio STOP_TIME_NS=$StopTimeNs"
    & $ghdl -r @ghdlFlags cpu_in_bridge_superram_tb @genericArgs 2>&1 | Tee-Object -FilePath $logPath
    Write-Host "log: $logPath"
}
finally {
    Pop-Location
}
