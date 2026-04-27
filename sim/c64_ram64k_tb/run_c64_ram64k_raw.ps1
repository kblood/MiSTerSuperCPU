#requires -Version 5.1
# c64_ram64k RAW-hazard regression: verifies the cycle-N+1 write-data forward
# in c64_ram64k.vhd that fixes Asterix decompressor hangs (commit b267455).
[CmdletBinding()]
param([string]$StopTime = "20us")

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

# Static structural check: the explicit a_din_d1 bypass mux MUST be present
# in c64_ram64k.vhd — GHDL's behavioral simulation cannot detect its removal
# (write-first VHDL semantics), but the M10K hazard on hardware needs it.
# Match a non-commented line that drives a_dout from a_din_d1 gated by a_we_d1.
$ramSrc = Join-Path $rtl 'c64_ram64k.vhd'
$bypassRegex = '^\s*a_dout\s*<=\s*a_din_d1\s+when\s+a_we_d1'
$hasBypass = $false
foreach ($line in Get-Content $ramSrc) {
    if ($line -match $bypassRegex) { $hasBypass = $true; break }
}
if (-not $hasBypass) {
    Write-Host "FAIL: c64_ram64k.vhd is missing the M10K RAW-hazard bypass mux." -ForegroundColor Red
    Write-Host "      Expected an uncommented assignment matching: $bypassRegex" -ForegroundColor Red
    Write-Host "      This is the fix from commit b267455 (Asterix title screen)." -ForegroundColor Red
    exit 1
}
Write-Host "structural check: bypass mux present in c64_ram64k.vhd"

$sources = @(
    (Join-Path $rtl 'c64_ram64k.vhd'),
    (Join-Path $scriptDir 'c64_ram64k_raw_tb.vhd')
)

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")
Push-Location $workDir
try {
    foreach ($s in $sources) {
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }
    & $ghdl -e @ghdlFlags c64_ram64k_raw_tb
    if ($LASTEXITCODE -ne 0) { throw "elab failed" }

    $logPath = Join-Path $workDir 'c64_ram64k_raw.log'
    & $ghdl -r @ghdlFlags c64_ram64k_raw_tb --stop-time=$StopTime 2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE
    Write-Host ""
    Write-Host "log: $logPath"
    if ($rc -ne 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
