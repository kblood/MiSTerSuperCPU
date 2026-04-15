#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the MiSTer C64 FPGA core using Quartus (WSL or Windows).

.DESCRIPTION
    Automates the full Quartus Prime compilation flow for the C64 MiSTer core.
    Clones the repo if needed, applies PLL compatibility fixes, runs synthesis
    via WSL, and copies the output .rbf file to the project root.

.PARAMETER Clean
    Remove previous build artifacts before compiling.

.PARAMETER SyntaxOnly
    Run analysis and elaboration only (no fitting/routing/bitstream).

.PARAMETER Debug
    Build with DEBUG_ENABLE=1 (all instrumentation active — crash trace ring
    buffer, debug overlay, UART debug stream, REU/SuperRAM diagnostic counters).
    This is the default and matches the committed source state.

.PARAMETER Release
    Build with DEBUG_ENABLE=0. Gates out all debug-only RTL, recovering
    ~1500-2500 ALMs and restoring positive clk32 setup slack. Use for timing
    stress tests or a shipping core. Before invoking Quartus, this flag
    patches the QSF VERILOG_MACRO and the VHDL DEBUG_ENABLE generic default
    in fpga64_sid_iec.vhd; the originals are restored on exit via try/finally.

.PARAMETER QuartusPath
    Override the Quartus install path inside WSL.
    Default: auto-detected from ~/intelFPGA_lite/*/quartus/bin
    Preference order: 17.x first (best MiSTer compatibility), then latest.

.PARAMETER UseWindowsQuartus
    Build using Windows Quartus instead of WSL Quartus.

.PARAMETER QuartusWinBin
    Windows Quartus bin64 path used with -UseWindowsQuartus.
    Default: C:\intelFPGA_lite\17.0\quartus\bin64 (or $env:QUARTUS_WIN_BIN).

.PARAMETER PreferLatestQuartus
    If set and QuartusPath is not provided, auto-detection picks the latest
    installed Quartus version instead of preferring 17.x.

.PARAMETER Program
    After a successful build, program the FPGA via USB Blaster using Windows Quartus.
    Default path: C:\intelFPGA_lite\17.0\quartus\bin64 (or set $env:QUARTUS_WIN_BIN).

.EXAMPLE
    .\build_c64.ps1                       # debug build (default)
    .\build_c64.ps1 -Release              # release build (DEBUG_ENABLE=0)
    .\build_c64.ps1 -Clean
    .\build_c64.ps1 -SyntaxOnly
    .\build_c64.ps1 -Program              # build then auto-program via USB Blaster
    .\build_c64.ps1 -Release -Clean       # clean release build
    .\build_c64.ps1 -QuartusPath "/home/user/intelFPGA_lite/17.0/quartus/bin"
    .\build_c64.ps1 -UseWindowsQuartus
#>

param(
    [switch]$Clean,
    [switch]$SyntaxOnly,
    [switch]$Program,
    [switch]$Debug,
    [switch]$Release,
    [string]$QuartusPath = "",
    [switch]$UseWindowsQuartus,
    [string]$QuartusWinBin = "",
    [switch]$PreferLatestQuartus
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$CoreDir = Join-Path $ProjectRoot "C64_MiSTer"
$RepoUrl = "https://github.com/MiSTer-devel/C64_MiSTer.git"

# --- DEBUG_ENABLE flavor selection ---
if ($Debug -and $Release) {
    Write-Host "ERROR: -Debug and -Release are mutually exclusive." -ForegroundColor Red
    exit 1
}
# Default (neither specified) = debug. Preserves existing workflow.
$DebugEnable = $true
if ($Release) { $DebugEnable = $false }
$DebugEnableInt = if ($DebugEnable) { 1 } else { 0 }
$DebugEnableVhdl = if ($DebugEnable) { "true" } else { "false" }
$BuildFlavor = if ($DebugEnable) { "DEBUG (instrumented)" } else { "RELEASE (DEBUG_ENABLE=0)" }
Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  Build flavor: $BuildFlavor" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

function Write-Step($msg) {
    Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Test-WSL {
    try {
        $result = wsl --list --quiet 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-WSLPath($winPath) {
    $resolved = (Resolve-Path $winPath).Path
    $drive = $resolved.Substring(0, 1).ToLower()
    $rest = $resolved.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Invoke-WSL($command) {
    # Use --noprofile --norc to avoid PATH issues with parentheses in Windows paths
    $output = wsl bash --noprofile --norc -c $command 2>&1
    return $output
}

# --- Preflight checks ---

Write-Step "Checking prerequisites"

if ($UseWindowsQuartus) {
    if ($QuartusWinBin -eq "") {
        $QuartusWinBin = if ($env:QUARTUS_WIN_BIN) { $env:QUARTUS_WIN_BIN } else { "C:\intelFPGA_lite\17.0\quartus\bin64" }
    }
    $quartusShWin = Join-Path $QuartusWinBin "quartus_sh.exe"
    if (-not (Test-Path $quartusShWin)) {
        Write-Host "ERROR: quartus_sh.exe not found at $quartusShWin" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Build backend: Windows Quartus"
    Write-Host "  Quartus bin: $QuartusWinBin"
    $versionLine = (& $quartusShWin --version 2>&1 | Select-String "Version" | Select-Object -First 1).ToString()
    if ([string]::IsNullOrWhiteSpace($versionLine)) {
        Write-Host "ERROR: quartus_sh not functional at $quartusShWin" -ForegroundColor Red
        exit 1
    }
    Write-Host "  $versionLine"
    $quartusVer = if ($versionLine -match "Version (\d+)\.") { $Matches[1] } else { "17" }
} else {
    if (-not (Test-WSL)) {
        Write-Host "ERROR: WSL is not available. Install WSL2 with Ubuntu, or use -UseWindowsQuartus." -ForegroundColor Red
        exit 1
    }
    Write-Host "  WSL: OK"

    # Auto-detect Quartus path if not specified
    if ($QuartusPath -eq "") {
        Write-Host "  Detecting Quartus installation in WSL..."
        if ($PreferLatestQuartus) {
            $detected = Invoke-WSL "ls -d `$HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | tail -1"
        } else {
            $detected = Invoke-WSL "ls -d `$HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | grep -E '/17\\.' | tail -1"
            if (($detected | Out-String).Trim() -eq "") {
                $detected = Invoke-WSL "ls -d `$HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | tail -1"
            }
        }
        $detected = ($detected | Out-String).Trim()

        if ($detected -eq "" -or $detected -match "No such file") {
            Write-Host "ERROR: Quartus not found in WSL. Install Quartus Prime Lite in WSL, or use -UseWindowsQuartus." -ForegroundColor Red
            Write-Host "  See BUILD_GUIDE.md for installation instructions." -ForegroundColor Yellow
            exit 1
        }
        $QuartusPath = $detected
    }

    Write-Host "  Quartus: $QuartusPath"

    # Verify quartus_sh works
    $version = Invoke-WSL "$QuartusPath/quartus_sh --version 2>&1 | grep Version"
    $version = ($version | Out-String).Trim()
    if ($version -eq "") {
        Write-Host "ERROR: quartus_sh not functional at $QuartusPath" -ForegroundColor Red
        exit 1
    }
    Write-Host "  $version"

    # Extract major version number for PLL fix
    $quartusVer = if ($version -match "Version (\d+)\.") { $Matches[1] } else { "22" }
    if (-not $PreferLatestQuartus -and $quartusVer -ne "17") {
        Write-Host "ERROR: Auto-detected Quartus $quartusVer, but this flow is pinned to Quartus 17 by default." -ForegroundColor Red
        Write-Host "  Options:" -ForegroundColor Yellow
        Write-Host "    - Install/use Quartus 17 and pass -QuartusPath explicitly" -ForegroundColor Yellow
        Write-Host "    - Or opt in to newer versions with -PreferLatestQuartus" -ForegroundColor Yellow
        Write-Host "    - Or use -UseWindowsQuartus" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "  Quartus major version: $quartusVer"

# --- Clone repo if needed ---

if (-not (Test-Path $CoreDir)) {
    Write-Step "Cloning C64 MiSTer core"
    git clone --recursive $RepoUrl $CoreDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to clone repository" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "`n  Core directory exists: $CoreDir"
}

# --- PLL compatibility fix ---

$pllFile = Join-Path $CoreDir "sys\pll_q${quartusVer}.qip"
$pllRef  = Join-Path $CoreDir "sys\pll_q17.qip"

if (-not (Test-Path $pllFile)) {
    if (Test-Path $pllRef) {
        Write-Step "Applying PLL fix for Quartus $quartusVer"
        Copy-Item $pllRef $pllFile
        Write-Host "  Created: sys\pll_q${quartusVer}.qip"
    } else {
        Write-Host "WARNING: Cannot find pll_q17.qip to create version-specific PLL file" -ForegroundColor Yellow
    }
} else {
    Write-Host "  PLL file exists: sys\pll_q${quartusVer}.qip"
}

# --- Clean if requested ---

if ($Clean) {
    Write-Step "Cleaning previous build artifacts"
    $outputDir = Join-Path $CoreDir "output_files"
    $dbDir = Join-Path $CoreDir "db"
    $incrDir = Join-Path $CoreDir "incremental_db"

    foreach ($dir in @($outputDir, $dbDir, $incrDir)) {
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
            Write-Host "  Removed: $dir"
        }
    }
}

# --- Patch DEBUG_ENABLE in QSF + VHDL ---
# Snapshot the original contents BEFORE modification so we can restore them
# on exit (success, failure, or Ctrl-C). The build script is the single
# source of truth for which flavor is being built — users should not edit
# the QSF or VHDL generic default directly.

$QsfPath    = Join-Path $CoreDir "C64.qsf"
$VhdlPath   = Join-Path $CoreDir "rtl\fpga64_sid_iec.vhd"
$QsfOrig    = $null
$VhdlOrig   = $null
$Patched    = $false

function Patch-DebugEnable {
    param([bool]$Enable)

    if (-not (Test-Path $QsfPath))  { throw "Cannot find QSF: $QsfPath" }
    if (-not (Test-Path $VhdlPath)) { throw "Cannot find VHDL: $VhdlPath" }

    $script:QsfOrig  = [System.IO.File]::ReadAllText($QsfPath)
    $script:VhdlOrig = [System.IO.File]::ReadAllText($VhdlPath)

    $macroVal = if ($Enable) { "1" } else { "0" }
    $vhdlVal  = if ($Enable) { "true" } else { "false" }

    # QSF: patch the VERILOG_MACRO DEBUG_ENABLE line.
    $qsfNew = $script:QsfOrig -replace `
        '(set_global_assignment\s+-name\s+VERILOG_MACRO\s+"DEBUG_ENABLE=)[01](")', `
        ('${1}' + $macroVal + '${2}')
    if ($qsfNew -eq $script:QsfOrig) {
        throw "QSF patch failed: VERILOG_MACRO DEBUG_ENABLE line not found in $QsfPath"
    }

    # VHDL: patch the DEBUG_ENABLE generic default value.
    $vhdlNew = $script:VhdlOrig -replace `
        '(DEBUG_ENABLE\s*:\s*boolean\s*:=\s*)(true|false)', `
        ('${1}' + $vhdlVal)
    if ($vhdlNew -eq $script:VhdlOrig) {
        throw "VHDL patch failed: DEBUG_ENABLE generic default not found in $VhdlPath"
    }

    [System.IO.File]::WriteAllText($QsfPath,  $qsfNew)
    [System.IO.File]::WriteAllText($VhdlPath, $vhdlNew)
    $script:Patched = $true

    Write-Host "  Patched QSF:  VERILOG_MACRO DEBUG_ENABLE=$macroVal" -ForegroundColor Gray
    Write-Host "  Patched VHDL: DEBUG_ENABLE generic default = $vhdlVal" -ForegroundColor Gray
}

function Restore-DebugEnable {
    if (-not $script:Patched) { return }
    if ($null -ne $script:QsfOrig) {
        [System.IO.File]::WriteAllText($QsfPath,  $script:QsfOrig)
    }
    if ($null -ne $script:VhdlOrig) {
        [System.IO.File]::WriteAllText($VhdlPath, $script:VhdlOrig)
    }
    $script:Patched = $false
    Write-Host "  Restored original QSF + VHDL (DEBUG_ENABLE pair)" -ForegroundColor Gray
}

# Guarantee restoration even if the shell is killed by Ctrl-C while Quartus
# is running. PowerShell's trap covers CancelKeyPress.
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
    if ($script:Patched) {
        try { Restore-DebugEnable } catch { }
    }
}

Write-Step "Patching DEBUG_ENABLE = $DebugEnableInt ($DebugEnableVhdl)"
Patch-DebugEnable -Enable $DebugEnable

# --- Build ---

$startTime = Get-Date

try {

if ($UseWindowsQuartus) {
    $quartusSh = Join-Path $QuartusWinBin "quartus_sh.exe"
    if ($SyntaxOnly) {
        Write-Step "Running syntax check (analysis & elaboration only)"
        $cmdDisplay = "$quartusSh --flow analysis_and_elaboration C64"
    } else {
        Write-Step "Running full compilation"
        $cmdDisplay = "$quartusSh --flow compile C64"
    }

    Write-Host "  Working directory: $CoreDir"
    Write-Host "  Command: $cmdDisplay"
    Write-Host ""

    Push-Location $CoreDir
    try {
        if ($SyntaxOnly) {
            & $quartusSh --flow analysis_and_elaboration C64
        } else {
            & $quartusSh --flow compile C64
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} else {
    $wslCorePath = Get-WSLPath $CoreDir
    if ($SyntaxOnly) {
        Write-Step "Running syntax check (analysis & elaboration only)"
        $buildCmd = "cd '$wslCorePath' && $QuartusPath/quartus_sh --flow analysis_and_elaboration C64 2>&1"
        $cmdDisplay = "quartus_sh --flow analysis_and_elaboration C64"
    } else {
        Write-Step "Running full compilation"
        $buildCmd = "cd '$wslCorePath' && $QuartusPath/quartus_sh --flow compile C64 2>&1"
        $cmdDisplay = "quartus_sh --flow compile C64"
    }

    Write-Host "  Working directory: $wslCorePath"
    Write-Host "  Command: $cmdDisplay"
    Write-Host ""

    # Run build via WSL, streaming output in real-time
    wsl bash --noprofile --norc -c $buildCmd
    $exitCode = $LASTEXITCODE
}

} finally {
    Restore-DebugEnable
}

$elapsed = (Get-Date) - $startTime

Write-Host ""

# --- Results ---

if ($SyntaxOnly) {
    if ($exitCode -eq 0) {
        Write-Step "Syntax check PASSED"
        Write-Host "  Elapsed: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Green
    } else {
        Write-Step "Syntax check FAILED"
        Write-Host "  Exit code: $exitCode" -ForegroundColor Red
        Write-Host "  Check output above for errors." -ForegroundColor Yellow
        exit $exitCode
    }
} else {
    $rbfPath = Join-Path $CoreDir "output_files\C64.rbf"

    if ($exitCode -eq 0 -and (Test-Path $rbfPath)) {
        $rbfSize = [math]::Round((Get-Item $rbfPath).Length / 1MB, 2)

        Write-Step "BUILD SUCCESSFUL"
        Write-Host "  Elapsed: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Green
        Write-Host "  Output:  $rbfPath ($rbfSize MB)" -ForegroundColor Green

        # Copy RBF to project root for easy access
        $destRbf = Join-Path $ProjectRoot "C64.rbf"
        Copy-Item $rbfPath $destRbf -Force
        Write-Host "  Copied:  $destRbf" -ForegroundColor Green

        # Auto-program via USB Blaster if -Program was specified
        if ($Program) {
            Write-Step "Programming FPGA via USB Blaster"
            $winQBin = if ($env:QUARTUS_WIN_BIN) { $env:QUARTUS_WIN_BIN } else { "C:\intelFPGA_lite\17.0\quartus\bin64" }
            $pgm = Join-Path $winQBin "quartus_pgm.exe"
            $sof = Join-Path $CoreDir "output_files\C64.sof"
            if (-not (Test-Path $pgm)) {
                Write-Host "  WARNING: quartus_pgm.exe not found at $winQBin" -ForegroundColor Yellow
                Write-Host "  Set `$env:QUARTUS_WIN_BIN to your Quartus bin64 directory." -ForegroundColor Yellow
            } elseif (-not (Test-Path $sof)) {
                Write-Host "  WARNING: .sof not found, cannot program" -ForegroundColor Yellow
            } else {
                $pgmResult = & $pgm -c "DE-SoC [USB-1]" -m JTAG -o "p;$sof@2" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  FPGA programmed successfully" -ForegroundColor Green
                } else {
                    Write-Host "  Programming failed (is USB Blaster connected?)" -ForegroundColor Yellow
                    $pgmResult | Select-String "Error|error" | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
                }
            }
        }

        # Show resource usage summary from fit report
        $fitSummary = Join-Path $CoreDir "output_files\C64.fit.summary"
        if (Test-Path $fitSummary) {
            Write-Host ""
            Write-Host "  Resource Summary:" -ForegroundColor Cyan
            Get-Content $fitSummary | ForEach-Object {
                Write-Host "    $_"
            }
        }
    } else {
        Write-Step "BUILD FAILED"
        Write-Host "  Exit code: $exitCode" -ForegroundColor Red
        Write-Host "  Check output above for errors." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Common fixes:" -ForegroundColor Yellow
        Write-Host "    - Missing PLL: ensure sys/pll_q${quartusVer}.qip exists" -ForegroundColor Yellow
        Write-Host "    - Try: .\build_c64.ps1 -Clean" -ForegroundColor Yellow
        exit 1
    }
}
