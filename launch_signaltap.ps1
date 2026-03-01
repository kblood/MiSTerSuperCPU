# launch_signaltap.ps1
# Opens Quartus Signal Tap II Logic Analyzer connected to the FPGA via USB Blaster.
# The design must have been compiled with Signal Tap embedded (run signaltap_setup.tcl
# and rebuild first, OR use the GUI to add signals and rebuild manually).
#
# Usage:  .\launch_signaltap.ps1

$QBin    = "C:\intelFPGA_lite\17.0\quartus\bin64"
$StpFile = "C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\supercpu_debug.stp"
$SofFile = "C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.sof"

$stpw = Join-Path $QBin "quartus_stpw.exe"
$jtag = Join-Path $QBin "jtagconfig.exe"

if (-not (Test-Path $stpw)) {
    Write-Error "quartus_stpw.exe not found at $QBin"
    exit 1
}

if (Test-Path $jtag) {
    Write-Host "JTAG chain:" -ForegroundColor Cyan
    & $jtag
}

if (Test-Path $StpFile) {
    Write-Host "Opening Signal Tap with: $StpFile" -ForegroundColor Cyan
    Start-Process $stpw -ArgumentList $StpFile
} else {
    Write-Host "No .stp file found - opening Signal Tap empty." -ForegroundColor Yellow
    Write-Host "To add signals: run  wsl quartus_sh -t signaltap_setup.tcl" -ForegroundColor Yellow
    Write-Host "then rebuild with:   .\build_c64.ps1" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Key signals to add manually in the GUI:" -ForegroundColor Cyan
    @(
        "emu|fpga64|cpuAddr[15..0]     - 16-bit CPU address",
        "emu|fpga64|addr_hi_816[7..0]  - 65C816 bank byte (A23..A16)",
        "emu|fpga64|cpuDi[7..0]        - data read by CPU",
        "emu|fpga64|cpuDo[7..0]        - data written by CPU",
        "emu|fpga64|cpuWe              - write enable",
        "emu|fpga64|enableCpu_816      - 65C816 clock enable",
        "emu|fpga64|supercpu_en        - SuperCPU mode active",
        "emu|fpga64|emu_mode_816       - 1=emulation, 0=native 65C816",
        "emu|fpga64|buslogic|scpu_rom_en - 1=serving SuperCPU ROM"
    ) | ForEach-Object { Write-Host "  $_" }
    Start-Process $stpw
}
