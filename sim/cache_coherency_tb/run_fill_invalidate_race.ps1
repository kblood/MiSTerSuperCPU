#requires -Version 5.1
# Bug 2 iter-22: in-flight fill vs CPU-write/invalidate ordering race.
[CmdletBinding()]
param([string]$StopTime = "3ms")

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$workDir   = Join-Path $scriptDir 'work_fillinv'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'cpu_cache.vhd'),
    (Join-Path $scriptDir 'cpu_cache_fill_invalidate_race_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_cache_fill_invalidate_race_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'fill_invalidate_race.log'
    & $ghdl -r @ghdlFlags cpu_cache_fill_invalidate_race_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"
    if ($rc -ne 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
