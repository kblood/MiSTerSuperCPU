#requires -Version 5.1
<#
.SYNOPSIS
    Build and run the Phase 4 C64 reduced-system harness (GHDL).

.DESCRIPTION
    Analyzes the 65C816 CPU core + cpu_65c816 wrapper + behavioral
    SDRAM model + c64_reduced_top + testbench, elaborates, and runs
    the simulation.

    The harness instantiates the REAL cpu_65c816 wrapper (pulling in
    the real P65C816 CPU core + MCode + ALU + AddrGen) and wires it
    to a behavioral memory system with:

      * 2-stage read latency for bank $00 / 3-stage for SuperRAM
      * inj_meminit state machine
      * bram_invalidate / cache_flush glue
      * 1-cycle-latency cache stub with the not-bram_invalidate gate

    Deliverables under work/:
      - c64_reduced_harness_tb.log    simulation transcript
      - c64_reduced_harness_tb.fst    FST waveform (pywellen / Surfer)

    Exit code 0 = PASS, non-zero = FAIL.

    No Quartus. No hardware. GHDL + --std=08 only.
#>

[CmdletBinding()]
param(
    [string]$StopTime = "10ms"
)

$ErrorActionPreference = 'Stop'

# --- locate GHDL ---
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) {
        throw "ghdl.exe not found. Install GHDL or fix the hard-coded path in run_harness.ps1."
    }
}

# --- repo paths (script lives at sim/c64_reduced_harness/run_harness.ps1) ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl816    = Join-Path $repoRoot 'C64_MiSTer\rtl\65C816'
$rtlBase   = Join-Path $repoRoot 'C64_MiSTer\rtl'
$phase2Dir = Join-Path $repoRoot 'sim\prg_loader_tb'
$commonDir = Join-Path $repoRoot 'sim\common\memory_models'
$workDir   = Join-Path $scriptDir 'work'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# --- source list (dependency order: package first, 816 core, wrapper, models, top, testbench) ---
$sources = @(
    # 65C816 CPU core (pure VHDL, no vendor IP)
    (Join-Path $rtl816 'P65816_pkg.vhd'),
    (Join-Path $rtl816 'BCDAdder.vhd'),
    (Join-Path $rtl816 'AddSubBCD.vhd'),
    (Join-Path $rtl816 'ALU.vhd'),
    (Join-Path $rtl816 'AddrGen.vhd'),
    (Join-Path $rtl816 'MCode.vhd'),
    (Join-Path $rtl816 'P65C816.vhd'),
    # C64 wrapper around P65C816
    (Join-Path $rtlBase 'cpu_65c816.vhd'),
    # Shared Phase 2 package (byte_array_t / expected_zp_t / hex helpers)
    (Join-Path $phase2Dir 'prg_loader_pkg.vhd'),
    # SDRAM behavioral model (Phase 3 common)
    (Join-Path $commonDir 'simple_sdram_model.vhd'),
    # Phase 4 files
    (Join-Path $scriptDir 'c64_reduced_top.vhd'),
    (Join-Path $scriptDir 'c64_reduced_harness_tb.vhd')
)

foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "Missing source: $s" }
}

# --- GHDL flags ---
# --ieee=synopsys to match the CPU core's use of std_logic_unsigned.
# -frelaxed is required for the 65C816 package bodies.
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
    & $ghdl -e @ghdlFlags c64_reduced_harness_tb
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }

    Write-Host "==> Run (stop-time=$StopTime)" -ForegroundColor Cyan
    $logPath  = Join-Path $workDir 'c64_reduced_harness_tb.log'
    $wavePath = Join-Path $workDir 'c64_reduced_harness_tb.fst'
    & $ghdl -r @ghdlFlags c64_reduced_harness_tb `
        --fst=$wavePath `
        --stop-time=$StopTime `
        --ieee-asserts=disable-at-0 `
        2>&1 | Tee-Object -FilePath $logPath
    $rc = $LASTEXITCODE

    Write-Host ""
    Write-Host "log:  $logPath"
    Write-Host "wave: $wavePath"
    if ($rc -eq 0) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
    } else {
        Write-Warning "RESULT: FAIL (ghdl -r exited $rc)"
    }
    exit $rc
} finally {
    Pop-Location
}
