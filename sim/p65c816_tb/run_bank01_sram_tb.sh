#!/usr/bin/env bash
# Phase D / Task #12: build + run bank01_sram_tb.
#
# Unit-level test for the bank-$01 SRAM shadow added to fpga64_buslogic.vhd.
# - On v165 (no bank01 dprom): EXPECTED FAIL (S1 reads return ramData=$00)
# - On v167 (bank01 dprom landed): EXPECTED PASS (all 3 scenarios green)

set -euo pipefail

STOP_TIME="${STOP_TIME:-200us}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
WORK_DIR="${SCRIPT_DIR}/work_bank01_sram"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

SOURCES=(
    "${RTL}/dprom.vhd"
    "${RTL}/fpga64_buslogic.vhd"
    "${SCRIPT_DIR}/bank01_sram_tb.vhd"
)

echo "==> Analyze (bank01_sram_tb)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" bank01_sram_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/bank01_sram_tb.log"
WAVE="${WORK_DIR}/bank01_sram_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" bank01_sram_tb \
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
