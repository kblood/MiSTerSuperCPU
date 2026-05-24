@echo off
REM Run sdram_pm_tb under Questa Altera Starter (handles inout tristate).
REM
REM Usage: run_questa.cmd [path-to-dut-v]
REM   Default DUT: C64_MiSTer/rtl/sdram_pm.v
REM
REM Exits 0 = bench errors==0; non-zero = errors>0 OR vsim error.
setlocal enableextensions enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "REPO=%SCRIPT_DIR%..\.."
set "RTL=%REPO%\C64_MiSTer\rtl"
set "WORK=%SCRIPT_DIR%work"

set "DUT=%~1"
if "%DUT%"=="" set "DUT=%RTL%\sdram_pm.v"

echo ==^> DUT: %DUT%

if exist "%WORK%" rd /s /q "%WORK%"
vlib "%WORK%"
vmap work "%WORK%"

vlog -sv -work work -suppress 2583,2275 "%SCRIPT_DIR%altddio_out_stub.sv" || exit /b 1
REM sdram_pm.v uses inout reg + unnamed-block reg decls; -mfcu enables the
REM relaxed-declarations parser without forcing strict SystemVerilog rules.
vlog -mfcu -work work -suppress 2583,2275 -suppress 12110 "%DUT%" || exit /b 1
vlog -sv -work work -suppress 2583,2275 "%SCRIPT_DIR%sdram_pm_tb.sv" || exit /b 1

vsim -c -do "run -all; quit -f" work.sdram_pm_tb > "%SCRIPT_DIR%run.log" 2>&1
type "%SCRIPT_DIR%run.log"

findstr /C:"PASS (errors=0)" "%SCRIPT_DIR%run.log" >nul
if errorlevel 1 (
    echo RESULT: FAIL
    exit /b 2
) else (
    echo RESULT: PASS
    exit /b 0
)
