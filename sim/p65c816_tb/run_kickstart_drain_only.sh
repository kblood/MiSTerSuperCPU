#!/usr/bin/env bash
# Phase A / Task #14 (#24): build + run p65c816_kickstart_drain_tb.
#
# Unit-level reproducer for the cpu_cache half of the v166 hardware failure.
# - On v165/v167 HEAD (cacheable_wr=0): EXPECTED — S_A1..A4 fail because
#   pushes never happen → cache stays at pre-fill values; S_B passes.
# - On v164 stash b140fb4 (cacheable_wr conditional + cpu_en gate):
#   EXPECTED — S_A all PASS (write-through coherent during drain).
#   S_B catches any new race introduced by the push during fetch.

set -euo pipefail

STOP_TIME="${STOP_TIME:-200us}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
WORK_DIR="${SCRIPT_DIR}/work_kickstart_drain"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

SOURCES=(
    "${RTL}/cpu_cache.vhd"
    "${SCRIPT_DIR}/p65c816_kickstart_drain_tb.vhd"
)

echo "==> Analyze (p65c816_kickstart_drain_tb)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" p65c816_kickstart_drain_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/p65c816_kickstart_drain_tb.log"
WAVE="${WORK_DIR}/p65c816_kickstart_drain_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" p65c816_kickstart_drain_tb \
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
