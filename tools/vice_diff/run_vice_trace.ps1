param(
  [string]$Prg = "C:\LLM\C64\MiSTerSuperCPU\asterix.prg",
  [string]$LogFile = "C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_trace.log",
  [int]$ChisLines = 500000,
  [int]$WaitSeconds = 90
)

$viceExe = "D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"
$cmds    = "C:\LLM\C64\MiSTerSuperCPU\tools\vice_diff\vice_trace_asterix.cmd"

if (-not (Test-Path $viceExe)) { throw "xscpu64.exe not found: $viceExe" }
if (-not (Test-Path $cmds))    { throw "moncommands not found: $cmds" }
if (-not (Test-Path $Prg))     { throw "PRG not found: $Prg" }

if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

$args = @(
  "-autostart", $Prg,
  "-moncommands", $cmds,
  "-monchislines", $ChisLines,
  "-logfile", $LogFile,
  "-logtofile",
  "-silent"
)

Write-Host "Launching xscpu64 with chis ring = $ChisLines, log = $LogFile"
$proc = Start-Process -FilePath $viceExe -ArgumentList $args -PassThru -WindowStyle Hidden

if (-not $proc.WaitForExit($WaitSeconds * 1000)) {
  Write-Warning "xscpu64 did not exit within ${WaitSeconds}s, killing"
  Stop-Process -Id $proc.Id -Force
}

if (Test-Path $LogFile) {
  $sz = (Get-Item $LogFile).Length
  Write-Host "Log written: $LogFile ($sz bytes)"
} else {
  Write-Warning "No log produced"
  exit 1
}
