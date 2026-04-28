#!/usr/bin/env bash
# Task #24 / Phase A: build and run the kernal-drain GHDL bench
# (c64_kernal_drain_tb).
#
# Reuses the same dependency graph as run_harness_v2.sh — patched copy
# of fpga64_sid_iec.vhd in build_staging/, all VHDL stubs for the
# Verilog children, the real cpu_cache + buslogic + 64KB BRAM. Only the
# top-level entity differs.
#
# Exit code 0 = PASS, non-zero = FAIL. Default stop time 80 ms is sized
# for the bench's own 2 M-cycle boot window (~63 ms) plus probe sweeps.

set -euo pipefail

STOP_TIME="${STOP_TIME:-80ms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging"
WORK_DIR="${SCRIPT_DIR}/work_kernal_drain"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}" "${STAGE}"

# ---- Stage + patch fpga64_sid_iec.vhd (same patches as run_harness_v2)
cp -f "${RTL}/fpga64_sid_iec.vhd" "${STAGE}/fpga64_sid_iec.vhd"
sed -i 's|when "11" => turbo_m <= "000"; -- 1x (C64 speed)|when "11" => turbo_m <= "000"; -- 1x (C64 speed)\n\t\t\t\t\t\t\twhen others => turbo_m <= "000";|' "${STAGE}/fpga64_sid_iec.vhd"

# Patch #3 (sim-only): force initial values on signals that depend on each other
# for boot. In synth, Quartus zero-inits these; in GHDL they stay 'U' forever
# and the rfsh_cycle = "00" gate that sets sysEnable never fires, leaving
# sysCycle stuck at CYCLE_EXT4 and the CPU never enabled. Without this, the
# 65C816 wedges at PC=$0000 (verified 2026-04-28).
sed -i \
    -e 's|^signal sysEnable    : std_logic;|signal sysEnable    : std_logic := '\''0'\'';|' \
    -e 's|^signal rfsh_cycle   : unsigned(1 downto 0);|signal rfsh_cycle   : unsigned(1 downto 0) := "00";|' \
    -e 's|^signal dma_active   : std_logic;|signal dma_active   : std_logic := '\''0'\'';|' \
    -e 's|^signal turbo_en     : std_logic;|signal turbo_en     : std_logic := '\''0'\'';|' \
    "${STAGE}/fpga64_sid_iec.vhd"
python3 - "${STAGE}/fpga64_sid_iec.vhd" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r', newline='') as f:
    src = f.read()
old = (
    "\tif rising_edge(clk32) then\n"
    "\t\tpreCycle <= sysCycleDef'succ(preCycle);\n"
    "\t\tif preCycle = sysCycleDef'high then\n"
    "\t\t\tpreCycle <= sysCycleDef'low;\n"
    "\t\t\tif sysEnable = '1' then\n"
    "\t\t\t\trfsh_cycle <= rfsh_cycle + 1;\n"
    "\t\t\tend if;\n"
    "\t\tend if;\n"
)
new = (
    "\tif rising_edge(clk32) then\n"
    "\t\tif preCycle = sysCycleDef'high then\n"
    "\t\t\tpreCycle <= sysCycleDef'low;\n"
    "\t\t\tif sysEnable = '1' then\n"
    "\t\t\t\trfsh_cycle <= rfsh_cycle + 1;\n"
    "\t\t\tend if;\n"
    "\t\telse\n"
    "\t\t\tpreCycle <= sysCycleDef'succ(preCycle);\n"
    "\t\tend if;\n"
)
if old in src:
    src = src.replace(old, new, 1)
    with open(p, 'w', newline='') as f:
        f.write(src)
    print("patch#2 applied")
else:
    print("patch#2: already applied or source shape changed")
PY

cd "${WORK_DIR}"

SOURCES=(
    "${RTL816}/P65816_pkg.vhd"
    "${RTL816}/BCDAdder.vhd"
    "${RTL816}/AddSubBCD.vhd"
    "${RTL816}/ALU.vhd"
    "${RTL816}/AddrGen.vhd"
    "${RTL816}/MCode.vhd"
    "${RTL816}/P65C816.vhd"
    "${RTL}/cpu_65c816.vhd"

    "${STUBS}/cpu_6510_stub.vhd"
    "${STUBS}/fpga64_rgbcolor_stub.vhd"
    "${STUBS}/mos6526_stub.vhd"
    "${STUBS}/sid_top_stub.vhd"

    "${RTL}/spram.vhd"
    "${RTL}/dprom.vhd"
    "${RTL}/bram_valid.vhd"
    "${RTL}/c64_ram64k_pkg.vhd"
    "${RTL}/c64_ram64k.vhd"
    "${RTL}/cpu_cache.vhd"
    "${RTL}/fpga64_keyboard.vhd"
    "${RTL}/fpga64_buslogic.vhd"
    "${RTL}/video_vicII_656x.vhd"

    "${STAGE}/fpga64_sid_iec.vhd"

    "${PHASE2_DIR}/prg_loader_pkg.vhd"
    "${COMMON_DIR}/simple_sdram_model.vhd"

    "${SCRIPT_DIR}/rom_loader_pkg.vhd"
    "${SCRIPT_DIR}/c64_reduced_top_v2.vhd"
    "${SCRIPT_DIR}/c64_kernal_drain_tb.vhd"
)

echo "==> Analyze (kernal-drain)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_kernal_drain_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_kernal_drain_tb.log"
WAVE="${WORK_DIR}/c64_kernal_drain_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_kernal_drain_tb \
    --fst="${WAVE}" \
    --stop-time="${STOP_TIME}" \
    --ieee-asserts=disable \
    2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
set -e

echo ""
echo "log:  ${LOG}"
echo "wave: ${WAVE}"
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (ghdl -r exited ${RC})"
fi
exit "${RC}"
