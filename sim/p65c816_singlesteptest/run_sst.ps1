#requires -Version 5.1
<#
.SYNOPSIS
    Build and run the SingleStepTests/65816 GHDL harness against P65C816.

.DESCRIPTION
    Analyzes the bare 65C816 sources + the SST harness, elaborates, and
    runs against a converter-produced text record file (see
    tools/sst_convert.py). Default = opcode 06.e, all 10000 cases.

.EXAMPLE
    # Phase 0 smoke (first 10 cases of opcode 06.e):
    .\run_sst.ps1 -InputFile ../../external/65816/v1.bin/06.e.txt -MaxCases 10

    # Full sweep (10000 cases):
    .\run_sst.ps1 -InputFile ../../external/65816/v1.bin/06.e.txt
#>

[CmdletBinding()]
param(
    [string]$InputFile = "../../external/65816/v1.bin/06.e.txt",
    [int]$MaxCases = 0,
    [switch]$VerboseEach,
    [string]$LogFile = "sst.log",
    [string]$StopTime = "5s"
)

$ErrorActionPreference = 'Stop'

# locate GHDL
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) {
        throw "ghdl.exe not found. Install GHDL or fix the hard-coded path in run_sst.ps1."
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl\65C816'
$workDir   = Join-Path $scriptDir 'work'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# Resolve input file relative to repoRoot if not absolute
if (-not [System.IO.Path]::IsPathRooted($InputFile)) {
    $resolvedInput = (Resolve-Path (Join-Path $scriptDir $InputFile) -ErrorAction SilentlyContinue).Path
    if (-not $resolvedInput) {
        $resolvedInput = (Resolve-Path (Join-Path $repoRoot $InputFile) -ErrorAction SilentlyContinue).Path
    }
    if (-not $resolvedInput) {
        throw "Cannot find input file: $InputFile"
    }
} else {
    $resolvedInput = $InputFile
}
Write-Host "input file: $resolvedInput"

# Source list (dependency order)
$sources = @(
    (Join-Path $rtl 'P65816_pkg.vhd'),
    (Join-Path $rtl 'BCDAdder.vhd'),
    (Join-Path $rtl 'AddSubBCD.vhd'),
    (Join-Path $rtl 'ALU.vhd'),
    (Join-Path $rtl 'AddrGen.vhd'),
    (Join-Path $rtl 'MCode.vhd'),
    (Join-Path $rtl 'P65C816.vhd'),
    (Join-Path $scriptDir 'sst_mem_pkg.vhd'),
    (Join-Path $scriptDir 'p65c816_sst_tb.vhd')
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

    Write-Host "==> Elaborate" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags p65c816_sst_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }

    $verboseStr = if ($VerboseEach) { "true" } else { "false" }

    $genericArgs = @(
        "-ginput_file=$resolvedInput",
        "-gmax_cases=$MaxCases",
        "-gverbose=$verboseStr"
    )

    Write-Host "==> Run (max_cases=$MaxCases verbose=$verboseStr stop=$StopTime)" -ForegroundColor Cyan
    $logPath = Join-Path $workDir $LogFile
    & $ghdl -r @ghdlFlags p65c816_sst_tb @genericArgs --stop-time=$StopTime 2>&1 |
        Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE

    Write-Host ""
    Write-Host "log: $logPath"
    Write-Host ""

    # Extract summary
    $summary = Select-String -Path $logPath -Pattern '^SST_RESULT' -SimpleMatch | Select-Object -Last 1
    if ($summary) {
        Write-Host $summary.Line -ForegroundColor Green
    } else {
        Write-Warning "No SST_RESULT line found in log"
    }

    exit $rc
} finally {
    Pop-Location
}
