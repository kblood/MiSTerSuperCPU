#!/usr/bin/env bash
# Run the scpu_sysram_tb GHDL bench.
# Standalone bench for the SuperCPU $D200-$D3FF I/O hole SRAM in
# fpga64_buslogic.vhd. Drives cpuAddr/cpuWe/cpuData directly; no full
# system instantiation needed.
#
# Exit code 0 = PASS (0 mismatches over 512 bytes), non-zero = FAIL.

set -euo pipefail
STOP_TIME="${STOP_TIME:-2ms}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
WORK_DIR="${SCRIPT_DIR}/work"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# fpga64_buslogic instantiates dprom (chargen, kernal, scpu_rom). The
# .mif INIT_FILE generic uses paths relative to the run-time CWD.
# We don't actually need ROM contents for this bench (test only touches
# scpu_sysram in $D200-$D3FF), but dprom must compile and the file paths
# must be lookup-able. Symlink the rtl tree so the relative paths resolve.
if [ ! -e rtl ]; then
    ln -s "${REPO_ROOT}/C64_MiSTer/rtl" rtl
fi

SOURCES=(
    "${RTL}/spram.vhd"
    "${RTL}/dprom.vhd"
    "${RTL}/fpga64_buslogic.vhd"
    "${SCRIPT_DIR}/scpu_sysram_tb.vhd"
)

echo "==> Analyze"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" scpu_sysram_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/scpu_sysram_tb.log"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" scpu_sysram_tb \
    --stop-time="${STOP_TIME}" --ieee-asserts=disable 2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
set -e

echo ""
echo "log: ${LOG}"
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS — \$D200-\$D3FF SRAM read/write verified."
else
    echo "RESULT: FAIL"
fi
exit "${RC}"
