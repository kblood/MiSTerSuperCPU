#requires -Version 5.1
<#
.SYNOPSIS
    Phase 4b: build and run the REAL-fpga64_sid_iec GHDL harness.

.DESCRIPTION
    Analyzes the full VHDL dependency graph of fpga64_sid_iec.vhd plus
    VHDL stubs for the Verilog children (mos6526, sid_top) and GHDL shims
    for the two files that cannot be parsed under --std=08 (cpu_6510,
    fpga64_rgbcolor). Also patches a staging copy of fpga64_sid_iec.vhd
    for two GHDL quirks (missing when-others in a case, and a sysCycle
    'succ evaluation that raises bounds on the wraparound cycle).

    Deliverables under work_v2/:
      - c64_reduced_harness_tb_v2.log  simulation transcript
      - c64_reduced_harness_tb_v2.fst  FST waveform

    Exit code 0 = PASS, non-zero = FAIL.
#>

[CmdletBinding()]
param(
    [string]$StopTime = "5ms"
)

$ErrorActionPreference = 'Stop'

$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) {
        throw "ghdl.exe not found"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl'
$rtl816    = Join-Path $rtl '65C816'
$phase2Dir = Join-Path $repoRoot 'sim\prg_loader_tb'
$commonDir = Join-Path $repoRoot 'sim\common\memory_models'
$stubs     = Join-Path $scriptDir 'stubs'
$stage     = Join-Path $scriptDir 'build_staging'
$workDir   = Join-Path $scriptDir 'work_v2'

foreach ($d in @($stage, $workDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# --- Staging: copy + patch fpga64_sid_iec.vhd ---
$srcIec  = Join-Path $rtl 'fpga64_sid_iec.vhd'
$dstIec  = Join-Path $stage 'fpga64_sid_iec.vhd'
Copy-Item $srcIec $dstIec -Force
$txt = Get-Content $dstIec -Raw

# Patch #1: add when others => to turbo_speed case
$needle1 = 'when "11" => turbo_m <= "000"; -- 1x (C64 speed)'
$repl1   = 'when "11" => turbo_m <= "000"; -- 1x (C64 speed)' + "`r`n`t`t`t`t`t`t`twhen others => turbo_m <= `"000`";"
if ($txt.Contains($needle1) -and -not $txt.Contains("when others => turbo_m <= `"000`";")) {
    $txt = $txt.Replace($needle1, $repl1)
}

# Patch #2: wrap 'succ guard on preCycle state machine
$needle2Pattern = "(?s)if rising_edge\(clk32\) then\s*\r?\n\s*preCycle <= sysCycleDef'succ\(preCycle\);\s*\r?\n\s*if preCycle = sysCycleDef'high then\s*\r?\n\s*preCycle <= sysCycleDef'low;\s*\r?\n\s*if sysEnable = '1' then\s*\r?\n\s*rfsh_cycle <= rfsh_cycle \+ 1;\s*\r?\n\s*end if;\s*\r?\n\s*end if;"
$repl2 = @"
if rising_edge(clk32) then
		if preCycle = sysCycleDef'high then
			preCycle <= sysCycleDef'low;
			if sysEnable = '1' then
				rfsh_cycle <= rfsh_cycle + 1;
			end if;
		else
			preCycle <= sysCycleDef'succ(preCycle);
		end if;
"@
$txt = [regex]::Replace($txt, $needle2Pattern, $repl2, 1)

Set-Content -Path $dstIec -Value $txt -NoNewline

$ghdlFlags = @('--std=08', '--ieee=synopsys', '-frelaxed', "--workdir=$workDir")

$sources = @(
    (Join-Path $rtl816 'P65816_pkg.vhd'),
    (Join-Path $rtl816 'BCDAdder.vhd'),
    (Join-Path $rtl816 'AddSubBCD.vhd'),
    (Join-Path $rtl816 'ALU.vhd'),
    (Join-Path $rtl816 'AddrGen.vhd'),
    (Join-Path $rtl816 'MCode.vhd'),
    (Join-Path $rtl816 'P65C816.vhd'),
    (Join-Path $rtl    'cpu_65c816.vhd'),
    # Shims
    (Join-Path $stubs  'cpu_6510_stub.vhd'),
    (Join-Path $stubs  'fpga64_rgbcolor_stub.vhd'),
    (Join-Path $stubs  'mos6526_stub.vhd'),
    (Join-Path $stubs  'sid_top_stub.vhd'),
    # Real VHDL children
    (Join-Path $rtl    'spram.vhd'),
    (Join-Path $rtl    'dprom.vhd'),
    (Join-Path $rtl    'bram_valid.vhd'),
    (Join-Path $rtl    'c64_ram64k.vhd'),
    (Join-Path $rtl    'cpu_cache.vhd'),
    (Join-Path $rtl    'fpga64_keyboard.vhd'),
    (Join-Path $rtl    'fpga64_buslogic.vhd'),
    (Join-Path $rtl    'video_vicII_656x.vhd'),
    # Real DUT (patched staging copy)
    (Join-Path $stage  'fpga64_sid_iec.vhd'),
    # Shared helpers
    (Join-Path $phase2Dir 'prg_loader_pkg.vhd'),
    (Join-Path $commonDir 'simple_sdram_model.vhd'),
    # Phase 4b top + ROM loader package + testbench
    (Join-Path $scriptDir 'rom_loader_pkg.vhd'),
    (Join-Path $scriptDir 'c64_reduced_top_v2.vhd'),
    (Join-Path $scriptDir 'c64_reduced_harness_tb_v2.vhd')
)

foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "Missing source: $s" }
}

Push-Location $workDir
try {
    Write-Host "==> Analyze (Phase 4b)" -ForegroundColor Cyan
    foreach ($s in $sources) {
        Write-Host "    $s"
        & $ghdl -a @ghdlFlags $s
        if ($LASTEXITCODE -ne 0) { throw "ghdl -a failed on $s" }
    }

    Write-Host "==> Elaborate" -ForegroundColor Cyan
    & $ghdl -e @ghdlFlags c64_reduced_harness_tb_v2
    if ($LASTEXITCODE -ne 0) { throw "ghdl -e failed" }

    Write-Host "==> Run (stop-time=$StopTime)" -ForegroundColor Cyan
    $logPath  = Join-Path $workDir 'c64_reduced_harness_tb_v2.log'
    $wavePath = Join-Path $workDir 'c64_reduced_harness_tb_v2.fst'
    & $ghdl -r @ghdlFlags c64_reduced_harness_tb_v2 `
        --fst=$wavePath `
        --stop-time=$StopTime `
        --ieee-asserts=disable `
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
