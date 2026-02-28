param(
    [string]$Manifest = ".\tools\rom_builder\profiles\debug_local.json",

    [string]$MisterHost = "192.168.50.130",
    [string]$User = "root",
    [int]$Port = 22,

    [string]$LocalDebugRom = ".\tools\rom_builder\out\debug_system.rom",
    [string]$RemoteDebugRom = "/media/usb0/Games/C64/C64 Kernals/debug_system.rom",

    [bool]$DeployRom = $true,
    [bool]$CopyCore = $true,

    [string]$LocalCoreRbf = ".\C64_MiSTer\output_files\C64.rbf",
    [string]$RemoteCoreRbf = "/media/fat/_Test/C64.rbf"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\.."))
$buildScript = Join-Path $repoRoot "tools\rom_builder\build_roms.ps1"
$deployScript = Join-Path $repoRoot "tools\rom_builder\deploy_to_mister.ps1"

function Resolve-RepoPath([string]$PathValue) {
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
}

if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Missing build script: $buildScript"
}
if (-not (Test-Path -LiteralPath $deployScript)) {
    throw "Missing deploy script: $deployScript"
}

$manifestAbs = Resolve-RepoPath $Manifest
$localDebugRomAbs = Resolve-RepoPath $LocalDebugRom
$localCoreRbfAbs = Resolve-RepoPath $LocalCoreRbf

Write-Host "Step 1/3: Building debug ROM artifacts from manifest..."
& $buildScript -Mode manifest -Manifest $manifestAbs

if ($DeployRom) {
    Write-Host "Step 2/3: Uploading debug system ROM..."
    & $deployScript -LocalFile $localDebugRomAbs -RemotePath $RemoteDebugRom -MisterHost $MisterHost -User $User -Port $Port
}
else {
    Write-Host "Step 2/3: Skipped debug ROM upload (DeployRom=false)."
}

if ($CopyCore) {
    if (-not (Test-Path -LiteralPath $localCoreRbfAbs)) {
        throw "Core .rbf not found (build separately first): $localCoreRbfAbs"
    }
    Write-Host "Step 3/3: Copying prebuilt core .rbf (no build)..."
    & $deployScript -LocalFile $localCoreRbfAbs -RemotePath $RemoteCoreRbf -MisterHost $MisterHost -User $User -Port $Port
}
else {
    Write-Host "Step 3/3: Skipped core copy (CopyCore=false)."
}

Write-Host "Done."
