#!/usr/bin/env bash
# Build and run the Phase 4 C64 reduced-system harness (GHDL).
#
# Exit code 0 = PASS, non-zero = FAIL.
# Deliverables under work/: c64_reduced_harness_tb.log, c64_reduced_harness_tb.fst

set -euo pipefail

STOP_TIME="${STOP_TIME:-10ms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RTL816="${REPO_ROOT}/C64_MiSTer/rtl/65C816"
RTL_BASE="${REPO_ROOT}/C64_MiSTer/rtl"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
WORK_DIR="${SCRIPT_DIR}/work"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
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
    "${RTL_BASE}/cpu_65c816.vhd"
    "${PHASE2_DIR}/prg_loader_pkg.vhd"
    "${COMMON_DIR}/simple_sdram_model.vhd"
    "${SCRIPT_DIR}/c64_reduced_top.vhd"
    "${SCRIPT_DIR}/c64_reduced_harness_tb.vhd"
)

echo "==> Analyze"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_reduced_harness_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_reduced_harness_tb.log"
WAVE="${WORK_DIR}/c64_reduced_harness_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_reduced_harness_tb \
    --fst="${WAVE}" \
    --stop-time="${STOP_TIME}" \
    --ieee-asserts=disable-at-0 \
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
