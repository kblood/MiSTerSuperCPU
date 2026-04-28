#!/usr/bin/env bash
# Task #24 / Phase A pivot: build + run cpu_cache_v164_tb.
#
# Narrow unit test for cpu_cache.vhd write-buffer push behavior.
# - On v163 HEAD (cacheable_wr <= '0'): EXPECTED FAIL (no pushes)
# - On v164 stash (cacheable_wr conditional + cpu_en gate): EXPECTED PASS

set -euo pipefail

STOP_TIME="${STOP_TIME:-200us}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
WORK_DIR="${SCRIPT_DIR}/work_cpu_cache_v164"

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
    "${SCRIPT_DIR}/cpu_cache_v164_tb.vhd"
)

echo "==> Analyze (cpu_cache_v164_tb)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" cpu_cache_v164_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/cpu_cache_v164_tb.log"
WAVE="${WORK_DIR}/cpu_cache_v164_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" cpu_cache_v164_tb \
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
