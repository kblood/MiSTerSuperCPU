#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$StopTime = "200us"
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
$workDir   = Join-Path $scriptDir 'work_ns'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'P65816_pkg.vhd'),
    (Join-Path $rtl 'BCDAdder.vhd'),
    (Join-Path $rtl 'AddSubBCD.vhd'),
    (Join-Path $rtl 'ALU.vhd'),
    (Join-Path $rtl 'AddrGen.vhd'),
    (Join-Path $rtl 'MCode.vhd'),
    (Join-Path $rtl 'P65C816.vhd'),
    (Join-Path $repoRoot 'C64_MiSTer\rtl\cpu_65c816.vhd'),
    (Join-Path $scriptDir 'p65c816_native_switch_tb.vhd'),
    (Join-Path $scriptDir 'cpu_65c816_native_switch_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags p65c816_native_switch_tb
    if ($LASTEXITCODE -ne 0) { throw "elab bare failed" }
    & $ghdl -e @ghdlFlags cpu_65c816_native_switch_tb
    if ($LASTEXITCODE -ne 0) { throw "elab wrap failed" }

    & $ghdl -r @ghdlFlags p65c816_native_switch_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath (Join-Path $workDir 'native_switch.log')
    $rc1 = $LASTEXITCODE
    & $ghdl -r @ghdlFlags cpu_65c816_native_switch_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath (Join-Path $workDir 'native_switch_wrapper.log')
    $rc2 = $LASTEXITCODE
    if ($rc1 -ne 0 -or $rc2 -ne 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
