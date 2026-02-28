param(
    [ValidateSet("system", "scpu", "manifest")]
    [string]$Mode = "manifest",

    [string]$Manifest,

    [string]$Basic,
    [string]$Kernal,
    [string]$Drive1541,
    [string]$Out,

    [string]$InputBin,
    [string]$OutMif,
    [int]$Depth = 65536,
    [string]$FillByteHex = "FF"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-PathSafe([string]$PathValue, [string]$BaseDir) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "Required path is missing."
    }
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $PathValue))
}

function Ensure-DirForFile([string]$FilePath) {
    $dir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Read-AllBytes([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
        throw "Missing file: $PathValue"
    }
    return [System.IO.File]::ReadAllBytes($PathValue)
}

function Write-SystemRom([string]$BasicPath, [string]$KernalPath, [string]$DrivePath, [string]$OutputPath) {
    $basicBytes  = Read-AllBytes $BasicPath
    $kernalBytes = Read-AllBytes $KernalPath
    $driveBytes  = Read-AllBytes $DrivePath

    if ($basicBytes.Length -ne 8192)  { throw "BASIC must be 8192 bytes. Got $($basicBytes.Length): $BasicPath" }
    if ($kernalBytes.Length -ne 8192) { throw "KERNAL must be 8192 bytes. Got $($kernalBytes.Length): $KernalPath" }
    if (($driveBytes.Length -ne 16384) -and ($driveBytes.Length -ne 32768)) {
        throw "1541 ROM must be 16384 or 32768 bytes. Got $($driveBytes.Length): $DrivePath"
    }

    $all = New-Object byte[] ($basicBytes.Length + $kernalBytes.Length + $driveBytes.Length)
    [Array]::Copy($basicBytes, 0, $all, 0, $basicBytes.Length)
    [Array]::Copy($kernalBytes, 0, $all, $basicBytes.Length, $kernalBytes.Length)
    [Array]::Copy($driveBytes, 0, $all, $basicBytes.Length + $kernalBytes.Length, $driveBytes.Length)

    Ensure-DirForFile $OutputPath
    [System.IO.File]::WriteAllBytes($OutputPath, $all)
    Write-Host "Built system ROM: $OutputPath ($($all.Length) bytes)"
}

function Write-ScpuMif([string]$InputPath, [string]$OutputPath, [int]$DepthValue, [byte]$FillByte) {
    if ($DepthValue -le 0) {
        throw "Depth must be > 0. Got: $DepthValue"
    }

    $inputBytes = Read-AllBytes $InputPath
    if ($inputBytes.Length -gt $DepthValue) {
        throw "Input bin too large for depth. bin=$($inputBytes.Length), depth=$DepthValue"
    }

    $all = New-Object byte[] $DepthValue
    for ($i = 0; $i -lt $DepthValue; $i++) {
        $all[$i] = $FillByte
    }
    [Array]::Copy($inputBytes, 0, $all, 0, $inputBytes.Length)

    Ensure-DirForFile $OutputPath
    $sw = New-Object System.IO.StreamWriter($OutputPath, $false, [System.Text.Encoding]::ASCII)
    try {
        $sw.WriteLine("WIDTH=8;")
        $sw.WriteLine("DEPTH=$DepthValue;")
        $sw.WriteLine("")
        $sw.WriteLine("ADDRESS_RADIX=HEX;")
        $sw.WriteLine("DATA_RADIX=HEX;")
        $sw.WriteLine("")
        $sw.WriteLine("CONTENT BEGIN")
        for ($i = 0; $i -lt $DepthValue; $i++) {
            $addr = "{0:X4}" -f $i
            $data = "{0:X2}" -f $all[$i]
            $sw.WriteLine("  $addr : $data;")
        }
        $sw.WriteLine("END;")
    }
    finally {
        $sw.Dispose()
    }
    Write-Host "Built SuperCPU MIF: $OutputPath (depth=$DepthValue, input=$($inputBytes.Length) bytes)"
}

function Parse-FillByte([string]$HexValue) {
    if ($HexValue -notmatch '^[0-9A-Fa-f]{2}$') {
        throw "fill byte must be exactly two hex chars (00-FF). Got: $HexValue"
    }
    return [Convert]::ToByte($HexValue, 16)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))

switch ($Mode) {
    "system" {
        $basicPath  = Resolve-PathSafe $Basic $repoRoot
        $kernalPath = Resolve-PathSafe $Kernal $repoRoot
        $drivePath  = Resolve-PathSafe $Drive1541 $repoRoot
        $outPath    = Resolve-PathSafe $Out $repoRoot
        Write-SystemRom -BasicPath $basicPath -KernalPath $kernalPath -DrivePath $drivePath -OutputPath $outPath
        break
    }
    "scpu" {
        $inPath  = Resolve-PathSafe $InputBin $repoRoot
        $outPath = Resolve-PathSafe $OutMif $repoRoot
        $fill    = Parse-FillByte $FillByteHex
        Write-ScpuMif -InputPath $inPath -OutputPath $outPath -DepthValue $Depth -FillByte $fill
        break
    }
    "manifest" {
        $manifestPath = Resolve-PathSafe $Manifest $repoRoot
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Manifest not found: $manifestPath"
        }
        $manifestDir = Split-Path -Parent $manifestPath
        $json = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        if ($json.PSObject.Properties.Name -contains "system_roms" -and $json.system_roms) {
            foreach ($entry in $json.system_roms) {
                $name = if ($entry.name) { [string]$entry.name } else { "unnamed-system" }
                $basicPath  = Resolve-PathSafe ([string]$entry.basic) $manifestDir
                $kernalPath = Resolve-PathSafe ([string]$entry.kernal) $manifestDir
                $drivePath  = Resolve-PathSafe ([string]$entry.drive1541) $manifestDir
                $outPath    = Resolve-PathSafe ([string]$entry.output) $manifestDir
                Write-Host "Building system ROM: $name"
                Write-SystemRom -BasicPath $basicPath -KernalPath $kernalPath -DrivePath $drivePath -OutputPath $outPath
            }
        }

        if ($json.PSObject.Properties.Name -contains "supercpu_mifs" -and $json.supercpu_mifs) {
            foreach ($entry in $json.supercpu_mifs) {
                $name = if ($entry.name) { [string]$entry.name } else { "unnamed-scpu" }
                $inPath  = Resolve-PathSafe ([string]$entry.input_bin) $manifestDir
                $outPath = Resolve-PathSafe ([string]$entry.output_mif) $manifestDir
                $depthValue = if ($entry.depth) { [int]$entry.depth } else { 65536 }
                $fillHex = if ($entry.fill_byte_hex) { [string]$entry.fill_byte_hex } else { "FF" }
                $fill = Parse-FillByte $fillHex
                Write-Host "Building SuperCPU MIF: $name"
                Write-ScpuMif -InputPath $inPath -OutputPath $outPath -DepthValue $depthValue -FillByte $fill
            }
        }
        break
    }
    default {
        throw "Unsupported mode: $Mode"
    }
}
