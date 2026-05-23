#requires -Version 5.1
# Stand-alone GHDL bench for scpu_async_bridge.
[CmdletBinding()]
param(
    [string]$StopTime = "15us",
    [int]$Ratio = 2,                           # clk_cpu : clk_sys (1, 2, 3 supported)
    [ValidateSet('1','0')][string]$Passthrough = '1'  # '1' = current diag, '0' = F.1 MCP FSM
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
$workDir   = Join-Path $scriptDir 'work'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$sources = @(
    (Join-Path $rtl 'scpu_async_bridge.vhd'),
    (Join-Path $scriptDir 'bridge_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags bridge_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $genericArgs = @("-gRATIO=$Ratio", "-gPASSTHROUGH_MODE='$Passthrough'")
    $logPath = Join-Path $workDir 'bridge_tb.log'
    Write-Host "Run: RATIO=$Ratio PASSTHROUGH_MODE=$Passthrough StopTime=$StopTime"
    & $ghdl -r @ghdlFlags bridge_tb @genericArgs --stop-time=$StopTime 2>&1 | Tee-Object -FilePath $logPath
    Write-Host ""
    Write-Host "log: $logPath"
}
finally {
    Pop-Location
}
