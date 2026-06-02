#requires -Version 5.1
# Alt-fire 2x consume-race bench: reproduces the iter-7g functional wedge and
# proves a correct gating policy. Sweeps all four GATE_MODEs.
[CmdletBinding()]
param([string]$StopTime = "300us")

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$workDir   = Join-Path $scriptDir 'work_altfire'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'cpu_cache.vhd'),
    (Join-Path $scriptDir 'cpu_cache_altfire_race_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_cache_altfire_race_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $modeName = @{ 3 = 'CONTROL (no alt, 4-apart)';
                   0 = 'iter-7g BUG (gate is a no-op)';
                   1 = 'TIMING-FIXED (decision 1clk later)';
                   2 = 'UNIFIED FIX (gap + same-line, stall)' }
    foreach ($m in 3,0,1,2) {
        Write-Host ""
        Write-Host "================ GATE_MODE=$m : $($modeName[$m]) ================"
        $logPath = Join-Path $workDir "altfire_mode$m.log"
        & $ghdl -r @ghdlFlags cpu_cache_altfire_race_tb "-gGATE_MODE=$m" --stop-time=$StopTime 2>&1 |
            Tee-Object -FilePath $logPath
    }
    Write-Host ""
    Write-Host "logs in $workDir"
}
finally {
    Pop-Location
}
