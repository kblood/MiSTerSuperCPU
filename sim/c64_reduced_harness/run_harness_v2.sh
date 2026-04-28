#!/usr/bin/env bash
# Phase 4b: build and run the REAL-fpga64_sid_iec GHDL harness.
#
# Unlike run_harness.sh (Phase 4 v1), this runner pulls in the full
# VHDL dependency graph of fpga64_sid_iec.vhd along with VHDL stubs for
# every Verilog child module. The DUT is the real C64 core.
#
# Exit code 0 = PASS, non-zero = FAIL.
# Deliverables under work_v2/:
#   c64_reduced_harness_tb_v2.log  simulation transcript
#   c64_reduced_harness_tb_v2.fst  waveform

set -euo pipefail

STOP_TIME="${STOP_TIME:-5ms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
T65="${RTL}/t65"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging"
WORK_DIR="${SCRIPT_DIR}/work_v2"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}" "${STAGE}"

# --- Staging copy of fpga64_sid_iec.vhd + patches for GHDL quirks ---
# (1) case statement on turbo_speed lacks `when others` (std_logic_vector
#     is open-valued under VHDL-2008).
# (2) sysCycleDef'succ(preCycle) on high raises bounds even though the
#     next line overwrites with 'low; GHDL evaluates the RHS before the
#     guard kicks in.
cp -f "${RTL}/fpga64_sid_iec.vhd" "${STAGE}/fpga64_sid_iec.vhd"
# Patch #1: add when others to turbo_speed case
sed -i 's|when "11" => turbo_m <= "000"; -- 1x (C64 speed)|when "11" => turbo_m <= "000"; -- 1x (C64 speed)\n\t\t\t\t\t\t\twhen others => turbo_m <= "000";|' "${STAGE}/fpga64_sid_iec.vhd"
# Patch #2: wrap 'succ in the high-check guard
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

# Dependency order for GHDL analysis.
# Stubs and shims MUST precede the real files that reference them by the
# same entity name so the latest-analyzed-wins rule in GHDL binds the
# shim. For files not referenced by a shim, order is the natural bottom-up
# dependency graph.
SOURCES=(
    # 65C816 CPU core
    "${RTL816}/P65816_pkg.vhd"
    "${RTL816}/BCDAdder.vhd"
    "${RTL816}/AddSubBCD.vhd"
    "${RTL816}/ALU.vhd"
    "${RTL816}/AddrGen.vhd"
    "${RTL816}/MCode.vhd"
    "${RTL816}/P65C816.vhd"
    "${RTL}/cpu_65c816.vhd"

    # Shims for files GHDL cannot parse
    "${STUBS}/cpu_6510_stub.vhd"
    "${STUBS}/fpga64_rgbcolor_stub.vhd"

    # VHDL stubs for Verilog children
    "${STUBS}/mos6526_stub.vhd"
    "${STUBS}/sid_top_stub.vhd"

    # Real VHDL children of fpga64_sid_iec
    "${RTL}/spram.vhd"
    "${RTL}/dprom.vhd"
    "${RTL}/bram_valid.vhd"
    "${RTL}/c64_ram64k_pkg.vhd"
    "${RTL}/c64_ram64k.vhd"
    "${RTL}/cpu_cache.vhd"
    "${RTL}/fpga64_keyboard.vhd"
    "${RTL}/fpga64_buslogic.vhd"
    "${RTL}/video_vicII_656x.vhd"

    # The REAL DUT (patched staging copy)
    "${STAGE}/fpga64_sid_iec.vhd"

    # Shared helpers
    "${PHASE2_DIR}/prg_loader_pkg.vhd"
    "${COMMON_DIR}/simple_sdram_model.vhd"

    # Phase 4b top + ROM loader package
    "${SCRIPT_DIR}/rom_loader_pkg.vhd"
    "${SCRIPT_DIR}/c64_reduced_top_v2.vhd"
    "${SCRIPT_DIR}/c64_reduced_harness_tb_v2.vhd"
)

echo "==> Analyze (Phase 4b)"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_reduced_harness_tb_v2

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_reduced_harness_tb_v2.log"
WAVE="${WORK_DIR}/c64_reduced_harness_tb_v2.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_reduced_harness_tb_v2 \
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
