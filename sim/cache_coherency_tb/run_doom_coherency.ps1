#requires -Version 5.1
# Doom coherency hole hunt: SuperRAM write-invalidate + cpu_en-misalignment.
[CmdletBinding()]
param([string]$StopTime = "500us")

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$workDir   = Join-Path $scriptDir 'work_doom'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'cpu_cache.vhd'),
    (Join-Path $scriptDir 'cpu_cache_doom_coherency_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_cache_doom_coherency_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'doom_coherency.log'
    & $ghdl -r @ghdlFlags cpu_cache_doom_coherency_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"
    if ($rc -ne 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
