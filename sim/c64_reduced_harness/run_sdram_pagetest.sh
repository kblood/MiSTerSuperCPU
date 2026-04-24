#!/usr/bin/env bash
# Run the SDRAM page-write pattern test for the $82-$8E corruption bug.
# Same build pipeline as run_harness_v2.sh but replaces the final testbench.

set -euo pipefail
STOP_TIME="${STOP_TIME:-50ms}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging"
WORK_DIR="${SCRIPT_DIR}/work_v2"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

# Assumes run_harness_v2.sh has been run at least once so staging patches
# and WORK_DIR exist. If not, run that first — it does the fpga64 patches.
if [ ! -f "${STAGE}/fpga64_sid_iec.vhd" ]; then
    echo "error: ${STAGE}/fpga64_sid_iec.vhd missing. Run run_harness_v2.sh first." >&2
    exit 2
fi

mkdir -p "${WORK_DIR}"
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
    "${STAGE}/c64_ram64k.vhd"
    "${RTL}/cpu_cache.vhd"
    "${RTL}/fpga64_keyboard.vhd"
    "${RTL}/fpga64_buslogic.vhd"
    "${RTL}/video_vicII_656x.vhd"
    "${STAGE}/fpga64_sid_iec.vhd"
    "${PHASE2_DIR}/prg_loader_pkg.vhd"
    "${COMMON_DIR}/simple_sdram_model.vhd"
    "${SCRIPT_DIR}/rom_loader_pkg.vhd"
    "${SCRIPT_DIR}/c64_reduced_top_v2.vhd"
    "${SCRIPT_DIR}/c64_sdram_pagetest_tb.vhd"
)

echo "==> Analyze"
for s in "${SOURCES[@]}"; do
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_sdram_pagetest_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_sdram_pagetest_tb.log"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_sdram_pagetest_tb \
    --stop-time="${STOP_TIME}" --ieee-asserts=disable 2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
set -e

echo ""
echo "log: ${LOG}"
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS — bug is NOT in fpga64_sid_iec ioctl→SDRAM routing."
    echo "        Next: escalate sim to include c64.sv io_cycle + real sdram.v."
else
    echo "RESULT: FAIL — bug IS reproducible in simplified harness. Proceed to fix."
fi
exit "${RC}"
