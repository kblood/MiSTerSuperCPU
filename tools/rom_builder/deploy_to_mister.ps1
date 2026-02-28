param(
    [Parameter(Mandatory = $true)]
    [string]$LocalFile,

    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    [string]$MisterHost = "192.168.50.130",
    [string]$User = "root",
    [int]$Port = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$localAbs = [System.IO.Path]::GetFullPath($LocalFile)
if (-not (Test-Path -LiteralPath $localAbs)) {
    throw "Local file not found: $localAbs"
}

$target = "$User@$MisterHost" + ":" + $RemotePath
Write-Host "Uploading:"
Write-Host "  local : $localAbs"
Write-Host "  remote: $target"

& scp -P $Port $localAbs $target
if ($LASTEXITCODE -ne 0) {
    throw "scp failed with exit code $LASTEXITCODE"
}

Write-Host "Upload complete."
