<#
.SYNOPSIS
    Build all debug CRT cartridges and deploy them to MiSTer.

.DESCRIPTION
    Runs every Python CRT generator in tools/test_cart/ then uploads all
    resulting .crt files to /media/fat/ on the MiSTer so they appear in the
    OSD cartridge browser.

    Load on hardware:
        OSD (F12) -> Load Cartridge -> select scpu_vic_test.crt
        Enable SuperCPU in OSD before loading to reproduce the artifact.

    Interpret results (see HYPOTHESIS_TRACKER.md):
        All 'A' + GREEN border -> no artifact without KERNAL (KERNAL-workload bug)
        '@' chars  + GREEN border -> H23/H27 confirmed (VIC read-side corruption)
        '@' chars  + RED  border  -> CPU also reads $00 (write-side / RAM issue)

.PARAMETER MisterHost
    IP or hostname of the MiSTer. Default: 192.168.50.130

.PARAMETER User
    SSH username. Default: root

.PARAMETER Port
    SSH/SCP port. Default: 22

.PARAMETER RemotePath
    Destination directory on MiSTer. Default: /media/fat/
    Files are uploaded as <RemotePath>/<filename>.crt

.PARAMETER BuildOnly
    Build CRT files but do not upload.

.PARAMETER DeployOnly
    Upload previously built CRT files without rebuilding.

.EXAMPLE
    .\build_and_deploy_carts.ps1
    Build and deploy everything with defaults.

.EXAMPLE
    .\build_and_deploy_carts.ps1 -BuildOnly
    Generate CRT files locally only (no network needed).

.EXAMPLE
    .\build_and_deploy_carts.ps1 -DeployOnly
    Re-deploy already-built CRT files (skips Python step).

.EXAMPLE
    .\build_and_deploy_carts.ps1 -MisterHost 192.168.1.50 -RemotePath /media/usb0/
    Deploy to a different host / path.
#>
param(
    [string]$MisterHost  = "192.168.50.130",
    [string]$User        = "root",
    [int]   $Port        = 22,
    [string]$RemotePath  = "/media/fat/",
    [switch]$BuildOnly,
    [switch]$DeployOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ──────────────────────────────────────────────────────────────────
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
$outDir     = Join-Path $scriptDir "out"
$deployScript = Join-Path $repoRoot "tools\rom_builder\deploy_to_mister.ps1"

# ── Generators: add new entries here as more CRT generators are created ────
# Each entry: @{ Script = relative path; Args = argument list }
$generators = @(
    @{ Script = "gen_scpu_test.py";  Args = @()           ; Label = "Basic Fill & Verify" },
    @{ Script = "gen_scpu_test.py";  Args = @("--stress") ; Label = "Bus Stress variant"  }
)

# ── Step 1: Build ─────────────────────────────────────────────────────────
if (-not $DeployOnly) {
    Write-Host ""
    Write-Host "=== BUILD ===" -ForegroundColor Cyan

    # Ensure output directory exists
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir | Out-Null
    }

    foreach ($gen in $generators) {
        $scriptPath = Join-Path $scriptDir $gen.Script
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "Generator not found, skipping: $scriptPath"
            continue
        }

        $argStr = if ($gen.Args) { " " + ($gen.Args -join " ") } else { "" }
        Write-Host ""
        Write-Host "  [$($gen.Label)]  python $($gen.Script)$argStr"

        Push-Location $scriptDir
        try {
            & python $gen.Script @($gen.Args) 2>&1 | ForEach-Object {
                Write-Host "    $_"
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Generator exited with code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    }

    Write-Host ""
    Write-Host "Build complete. CRT files in: $outDir"
} else {
    Write-Host "DeployOnly: skipping build step."
}

# ── Step 2: Deploy ─────────────────────────────────────────────────────────
if (-not $BuildOnly) {
    Write-Host ""
    Write-Host "=== DEPLOY ===" -ForegroundColor Cyan

    if (-not (Test-Path $deployScript)) {
        throw "Deploy helper not found: $deployScript"
    }

    $crtFiles = Get-ChildItem -Path $outDir -Filter "*.crt" -ErrorAction SilentlyContinue
    if (-not $crtFiles) {
        throw "No .crt files found in $outDir - run without -DeployOnly first."
    }

    # Ensure remote path ends with /
    $remoteDir = $RemotePath.TrimEnd("/") + "/"

    foreach ($crt in $crtFiles) {
        $remoteDest = $remoteDir + $crt.Name
        Write-Host ""
        Write-Host "  Deploying: $($crt.Name)"
        & $deployScript `
            -LocalFile  $crt.FullName `
            -RemotePath $remoteDest `
            -MisterHost $MisterHost `
            -User       $User `
            -Port       $Port
    }

    Write-Host ""
    Write-Host "Deploy complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "On MiSTer:" -ForegroundColor Yellow
    Write-Host "  F12 -> Load Cartridge -> scpu_vic_test.crt"
    Write-Host "  Enable SuperCPU in OSD before loading."
    Write-Host ""
    Write-Host "Interpret results:"
    Write-Host "  All 'A' + GREEN border  -> no '@' without KERNAL  (KERNAL-workload bug)"
    Write-Host "  '@' chars + GREEN border -> H23/H27 CONFIRMED      (VIC read-side clobber)"
    Write-Host "  '@' chars + RED  border  -> CPU also reads wrong    (write-side / RAM bug)"
} else {
    Write-Host "BuildOnly: skipping deploy step."
}
