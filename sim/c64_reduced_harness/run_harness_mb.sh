#!/usr/bin/env bash
# Milestone B system-level harness: real fpga64_sid_iec with the 65C816
# actually clocked (clk_cpu driven), MCP async bridge selectable.
#
#   RATIO=1 MCP=0  → passthrough, clk_cpu=32MHz (real-HW baseline)
#   RATIO=2 MCP=1  → Milestone B, clk_cpu=64MHz across the MCP bridge
#
# Env: RATIO (default 2), MCP (default 1), RUN_CYCLES (default 40000),
#      STOP_TIME (default 8ms).
#
# Exit 0 = PASS, non-zero = FAIL.

set -euo pipefail

RATIO="${RATIO:-2}"
MCP="${MCP:-1}"
RUN_CYCLES="${RUN_CYCLES:-40000}"
STOP_TIME="${STOP_TIME:-8ms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging_mb"
WORK_DIR="${SCRIPT_DIR}/work_mb"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}" "${STAGE}"

# --- Staging copy of fpga64_sid_iec.vhd + the two GHDL-quirk patches
# (identical to run_harness_v2.sh). ---
cp -f "${RTL}/fpga64_sid_iec.vhd" "${STAGE}/fpga64_sid_iec.vhd"
sed -i 's|when "11" => turbo_m <= "000"; -- 1x (C64 speed)|when "11" => turbo_m <= "000"; -- 1x (C64 speed)\n\t\t\t\t\t\t\twhen others => turbo_m <= "000";|' "${STAGE}/fpga64_sid_iec.vhd"
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
    "${RTL}/scpu_async_bridge.vhd"
    "${STAGE}/fpga64_sid_iec.vhd"
    "${PHASE2_DIR}/prg_loader_pkg.vhd"
    "${COMMON_DIR}/simple_sdram_model.vhd"
    "${SCRIPT_DIR}/rom_loader_pkg.vhd"
    "${SCRIPT_DIR}/c64_reduced_top_v2.vhd"
    "${SCRIPT_DIR}/c64_reduced_harness_tb_mb.vhd"
)

echo "==> Analyze (Milestone B harness)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_reduced_harness_tb_mb

echo "==> Run RATIO=${RATIO} MCP=${MCP} RUN_CYCLES=${RUN_CYCLES} (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_reduced_harness_tb_mb_R${RATIO}_MCP${MCP}.log"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_reduced_harness_tb_mb \
    "-gRATIO=${RATIO}" "-gMCP=${MCP}" "-gRUN_CYCLES=${RUN_CYCLES}" \
    --stop-time="${STOP_TIME}" \
    --ieee-asserts=disable \
    2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
set -e

echo ""
echo "log:  ${LOG}"
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (ghdl -r exited ${RC})"
fi
exit "${RC}"
