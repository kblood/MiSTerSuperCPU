#!/usr/bin/env bash
# Build and run the PRG-loader GHDL testbench.
#
# Exit code 0 = PASS, nonzero = FAIL (any assertion mismatch).
# Deliverables under work/: prg_loader_tb.log, prg_loader_tb.fst

set -euo pipefail

STOP_TIME="${STOP_TIME:-2ms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"

GHDL_FLAGS=(--std=08 --ieee=standard "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

SOURCES=(
    "${SCRIPT_DIR}/prg_loader_pkg.vhd"
    "${SCRIPT_DIR}/prg_loader_dut.vhd"
    "${SCRIPT_DIR}/prg_loader_tb.vhd"
)

echo "==> Analyze"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" prg_loader_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/prg_loader_tb.log"
WAVE="${WORK_DIR}/prg_loader_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" prg_loader_tb \
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
