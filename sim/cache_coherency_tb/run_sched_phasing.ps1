#requires -Version 5.1
# iter-15 scheduler-phasing bench: faithful registered `enableCpu <= fire` scheduler
# + real cpu_cache + _d1 override + modeled 816 consumer. Settles the LIVE-vs-_d1
# gate-input question off-device.
#   ALLOW_FAST=0  : CONTROL (mains only, 4-apart) — must PASS (validates the model).
#   ALLOW_FAST=1 GATE_INPUT=0 (LIVE) : must PASS warm AND cold (the realizable design).
#   ALLOW_FAST=1 GATE_INPUT=1 (D1)   : must FAIL (proves the brief's _d1 pseudocode is stale).
[CmdletBinding()]
param([string]$StopTime = "400us")

$ErrorActionPreference = 'Stop'
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$workDir   = Join-Path $scriptDir 'work_sched'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'cpu_cache.vhd'),
    (Join-Path $scriptDir 'cpu_cache_sched_phasing_tb.vhd')
)
$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags cpu_cache_sched_phasing_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    function Run($gi, $af, $pf, $label) {
        Write-Host ""
        Write-Host "================ $label ================"
        $log = Join-Path $workDir "sched_gi${gi}_af${af}_pf${pf}.log"
        & $ghdl -r @ghdlFlags cpu_cache_sched_phasing_tb `
            "-gGATE_INPUT=$gi" "-gALLOW_FAST=$af" "-gPREFILL=$pf" --stop-time=$StopTime 2>&1 |
            Tee-Object -FilePath $log | Select-String -Pattern '=== (PASS|FAIL|GATE_INPUT)','STALE','FAST-MISS','HIT wrong'
    }

    Write-Host "######## CONTROL: mains-only must PASS (model self-check) ########"
    Run 0 0 'true'  'CONTROL ALLOW_FAST=0 PREFILL=true'
    Run 0 0 'false' 'CONTROL ALLOW_FAST=0 PREFILL=false'

    Write-Host ""
    Write-Host "######## FAST, LIVE gate (the realizable design) — expect PASS ########"
    Run 0 1 'true'  'LIVE  ALLOW_FAST=1 PREFILL=true'
    Run 0 1 'false' 'LIVE  ALLOW_FAST=1 PREFILL=false (cold/hit-gate)'

    Write-Host ""
    Write-Host "######## FAST, D1 gate (brief pseudocode) — expect FAIL ########"
    Run 1 1 'true'  'D1    ALLOW_FAST=1 PREFILL=true'
    Run 1 1 'false' 'D1    ALLOW_FAST=1 PREFILL=false'

    Write-Host ""
    Write-Host "==> done. logs in $workDir"
} finally {
    Pop-Location
}
