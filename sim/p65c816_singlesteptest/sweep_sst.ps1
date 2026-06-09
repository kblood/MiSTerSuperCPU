#requires -Version 5.1
<#
.SYNOPSIS
    Sweep the P65C816 SST harness over many input files. Elaborates the
    bench ONCE, then re-runs the simulator binary against each input.

.DESCRIPTION
    Phase 1: 28 RMW opcodes both modes (56 runs).
    Phase 2: any subset (pass -Pattern '??.?.txt' to glob).

.EXAMPLE
    # Phase 1 RMW sweep (default):
    .\sweep_sst.ps1

    # Run only emu-mode RMW:
    .\sweep_sst.ps1 -Pattern '*.e.txt'

    # First 100 cases of each (smoke test):
    .\sweep_sst.ps1 -MaxCases 100
#>
[CmdletBinding()]
param(
    [string]$Pattern   = '*.txt',          # glob inside ../../external/65816/v1.bin/
    [string[]]$Opcodes = @('06','0e','16','1e','26','2e','36','3e',
                            '46','4e','56','5e','66','6e','76','7e',
                            '04','0c','14','1c',
                            'c6','ce','d6','de','e6','ee','f6','fe'),
    [string[]]$Modes   = @('e','n'),
    [int]$MaxCases     = 0,
    [string]$StopTime  = '60000ms',
    [string]$ResultDir = 'sweep_results',
    [switch]$GarbageInternal,               # drive D_IN garbage on internal cycles
    [switch]$All                            # discover opcode list from input dir
)

$ErrorActionPreference = 'Stop'

# Locate GHDL
$ghdl = "C:\Users\Caldor\AppData\Local\Microsoft\WinGet\Packages\ghdl.ghdl.ucrt64.mcode_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\ghdl.exe"
if (-not (Test-Path $ghdl)) {
    $ghdl = (Get-Command ghdl -ErrorAction SilentlyContinue).Source
    if (-not $ghdl) { throw "ghdl.exe not found." }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$rtl       = Join-Path $repoRoot 'C64_MiSTer\rtl\65C816'
$workDir   = Join-Path $scriptDir 'work'
$resDir    = Join-Path $scriptDir $ResultDir
$inputDir  = Join-Path $repoRoot 'external\65816\v1.bin'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }
if (-not (Test-Path $resDir))  { New-Item -ItemType Directory -Path $resDir  | Out-Null }

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

$flags = @('--std=08','--ieee=synopsys','-frelaxed',"--workdir=$workDir")

Push-Location $workDir
try {
    Write-Host "==> Analyze + Elaborate" -ForegroundColor Cyan
    foreach ($s in $sources) {
        & $ghdl -a @flags $s
        if ($LASTEXITCODE -ne 0) { throw "analyze failed: $s" }
    }
    & $ghdl -e @flags p65c816_sst_tb
    if ($LASTEXITCODE -ne 0) { throw "elaborate failed" }

    # Build target list
    $targets = @()
    if ($All) {
        $found = Get-ChildItem -Path $inputDir -Filter '*.txt' |
            Where-Object { $_.BaseName -match '^[0-9a-f]{2}\.[en]$' } |
            Sort-Object Name
        foreach ($file in $found) {
            $mode = $file.BaseName.Substring(3,1)
            if ($Modes -contains $mode) { $targets += $file.FullName }
        }
    } else {
        foreach ($op in $Opcodes) {
            foreach ($m in $Modes) {
                $f = Join-Path $inputDir "$op.$m.txt"
                if (Test-Path $f) { $targets += $f }
            }
        }
    }

    Write-Host ""
    Write-Host "==> Sweep ($($targets.Count) input files, max_cases=$MaxCases stop=$StopTime)" -ForegroundColor Cyan
    Write-Host ""

    $rows = @()
    $totalPass = 0; $totalFail = 0; $totalSkip = 0; $totalAll = 0
    $startWall = Get-Date

    foreach ($t in $targets) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($t)
        $log  = Join-Path $resDir "$name.log"
        $garbageStr = if ($GarbageInternal) { "true" } else { "false" }
        $args = @(
            "-ginput_file=$t",
            "-gmax_cases=$MaxCases",
            "-gverbose=false",
            "-ggarbage_internal=$garbageStr"
        )
        $t0 = Get-Date
        & $ghdl -r @flags p65c816_sst_tb @args --stop-time=$StopTime *> $log
        $rc = $LASTEXITCODE
        $elapsed = ((Get-Date) - $t0).TotalSeconds

        $line = (Select-String -Path $log -Pattern '^E?SST_RESULT' | Select-Object -Last 1).Line
        if ($line) {
            $line = $line -replace '^E?SST_RESULT\s+',''
            $kv = @{}
            foreach ($p in ($line -split '\s+')) {
                if ($p -match '^(\w+)=(\d+)$') { $kv[$matches[1]] = [int]$matches[2] }
            }
            $p_v = if ($kv.ContainsKey('pass'))  { $kv['pass']  } else { 0 }
            $f_v = if ($kv.ContainsKey('fail'))  { $kv['fail']  } else { 0 }
            $s_v = if ($kv.ContainsKey('skip'))  { $kv['skip']  } else { 0 }
            $tot = if ($kv.ContainsKey('total')) { $kv['total'] } else { ($p_v + $f_v + $s_v) }

            $totalPass += $p_v; $totalFail += $f_v; $totalSkip += $s_v; $totalAll += $tot
            $color = if ($f_v -eq 0) { 'Green' } elseif ($f_v -lt 10) { 'Yellow' } else { 'Red' }
            $msg = "{0,-8} pass={1,5} fail={2,4} skip={3,4} total={4,5}  [{5,5:N1}s]" -f $name,$p_v,$f_v,$s_v,$tot,$elapsed
            Write-Host $msg -ForegroundColor $color
            $rows += [pscustomobject]@{ Name=$name; Pass=$p_v; Fail=$f_v; Skip=$s_v; Total=$tot; Elapsed=$elapsed; rc=$rc }
        } else {
            Write-Host ("{0,-8} NO_RESULT (rc={1}, see {2})" -f $name,$rc,$log) -ForegroundColor Red
            $rows += [pscustomobject]@{ Name=$name; Pass=0; Fail=-1; Skip=0; Total=0; Elapsed=$elapsed; rc=$rc }
        }
    }

    $wall = ((Get-Date) - $startWall).TotalSeconds
    Write-Host ""
    Write-Host ("==> SUMMARY  pass={0} fail={1} skip={2} total={3}  ({4:N1}s wall)" -f $totalPass,$totalFail,$totalSkip,$totalAll,$wall) -ForegroundColor Cyan
    Write-Host ""

    $rows | Export-Csv -Path (Join-Path $resDir 'summary.csv') -NoTypeInformation
    Write-Host "summary csv: $(Join-Path $resDir 'summary.csv')"

    if ($totalFail -gt 0) {
        Write-Host ""
        Write-Host "==> Per-opcode FAIL detail:" -ForegroundColor Yellow
        foreach ($r in ($rows | Where-Object { $_.Fail -gt 0 })) {
            $log = Join-Path $resDir "$($r.Name).log"
            Write-Host "  $($r.Name): $($r.Fail) fail" -ForegroundColor Yellow
            Select-String -Path $log -Pattern '^E?FAIL case' |
                Select-Object -First 5 |
                ForEach-Object { Write-Host "    $($_.Line)" }
        }
    }

    exit ($(if ($totalFail -gt 0) { 1 } else { 0 }))
} finally {
    Pop-Location
}
