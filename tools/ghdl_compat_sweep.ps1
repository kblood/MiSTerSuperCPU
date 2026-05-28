#requires -Version 5.1
<#
.SYNOPSIS
    Off-device CPU-correctness baseline for the P65C816 core.

.DESCRIPTION
    Runs the existing per-scenario GHDL runners in sim/p65c816_tb (each in a
    child pwsh process so their `exit` / Push-Location don't leak), captures
    each log, and tabulates PASS/FAIL. This is the hardware-independent half of
    the compat baseline the autonomous loop keeps (the other half is the
    on-MiSTer Lorenz pass-rate + effective MHz).

    A runner is FAIL if it exits non-zero OR its log contains a strong fail
    marker (FAIL / MISMATCH / "severity failure"). PASS otherwise.

.PARAMETER IncludeAsterix
    Also run the heavier asterix demo-trace integration benches (these need
    gen_asterix_mem_init.py, which is run first).

.PARAMETER Only
    Run only the named runner script(s), e.g. -Only run_tb.ps1
#>
[CmdletBinding()]
param(
    [switch]$IncludeAsterix,
    [string[]]$Only
)

$ErrorActionPreference = 'Continue'
$repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tbDir  = Join-Path $repo 'sim\p65c816_tb'
$logDir = Join-Path $PSScriptRoot 'ghdl_sweep_logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# Curated core CPU-correctness runners (fast, no external mem-init).
# run_tb.ps1 already covers lda_long / REP / native-switch / xflag / copy-loop.
$core = @(
    'run_tb.ps1',
    'run_jml_indirect_long_only.ps1',
    'run_jml_long_crossbank_only.ps1',
    'run_jmp_indirect_pagewrap.ps1',
    'run_long_absx_carry_only.ps1',
    'run_sr_emu_wrap_only.ps1',
    'run_scpumips_copy_only.ps1'
)
$asterix = @(
    'run_asterix_phase1_only.ps1',
    'run_asterix_dispatcher_only.ps1',
    'run_asterix_overlay.ps1',
    'run_asterix_overlay_mirror.ps1',
    'run_asterix_postcb00_only.ps1',
    'run_asterix_full_only.ps1',
    'run_asterix_full_nmi.ps1'
)

if ($IncludeAsterix) {
    $gen = Join-Path $tbDir 'gen_asterix_mem_init.py'
    if (Test-Path $gen) {
        Write-Host "==> gen_asterix_mem_init.py" -ForegroundColor Cyan
        Push-Location $tbDir; & python $gen *> (Join-Path $logDir 'gen_asterix_mem_init.log'); Pop-Location
    }
}

$list = if ($Only) { $Only } elseif ($IncludeAsterix) { $core + $asterix } else { $core }

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }

$results = @()
foreach ($r in $list) {
    $path = Join-Path $tbDir $r
    if (-not (Test-Path $path)) {
        $results += [pscustomobject]@{ Runner = $r; Status = 'MISSING'; Exit = '-'; Sec = 0; Log = '' }
        continue
    }
    $log = Join-Path $logDir ($r -replace '\.ps1$', '.log')
    Write-Host "==> $r" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $pwsh -NoProfile -File $path *> $log
    $rc = $LASTEXITCODE
    $sw.Stop()
    $txt = (Get-Content $log -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $txt) { $txt = '' }
    $failMark = $txt -match 'FAIL|MISMATCH|severity failure'
    $status = if (($rc -eq 0) -and (-not $failMark)) { 'PASS' } else { 'FAIL' }
    $results += [pscustomobject]@{
        Runner = $r; Status = $status; Exit = $rc
        Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Log = $log
    }
    Write-Host ("    {0}  (exit {1}, {2}s)" -f $status, $rc, [math]::Round($sw.Elapsed.TotalSeconds,1))
}

Write-Host ""
$results | Format-Table Runner, Status, Exit, Sec -AutoSize
$pass = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$miss = ($results | Where-Object { $_.Status -eq 'MISSING' }).Count
$stamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
$summary = "GHDL CPU compat sweep $stamp : $pass PASS, $fail FAIL, $miss MISSING (of $($results.Count))"
$col = if ($fail -eq 0) { 'Green' } else { 'Yellow' }
Write-Host $summary -ForegroundColor $col

# Persist a one-line-per-runner baseline for the loop to diff against.
$out = Join-Path $PSScriptRoot 'ghdl_compat_sweep_results.txt'
$lines = @($summary, '')
$lines += ($results | ForEach-Object { "{0,-34} {1,-7} exit={2,-3} {3}s" -f $_.Runner, $_.Status, $_.Exit, $_.Sec })
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Host "baseline -> $out"
if ($fail -ne 0) { exit 1 } else { exit 0 }
