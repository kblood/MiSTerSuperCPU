#!/usr/bin/env bash
# iter-23: build + run the SYSTEM-level SuperRAM cache-coherency repro (Bug 2).
#
# Drives the REAL fpga64_sid_iec with a CPU long-store-then-read sequence to
# SuperRAM bank $20 (make_bug2_test_rom) and reports whether the cache returns
# a stale byte on the re-read.
#
#   CACHE_READ_PATH=0 ./run_superram_coherency.sh   # sanity (must read $4A)
#   CACHE_READ_PATH=1 ./run_superram_coherency.sh   # the real test (Bug 2?)
#
# Exit 0 = bench PASS (program ran + sanity ok). Grep the log for
# "SUPERRAM_COHERENCY:" to get the coherency verdict.

set -euo pipefail

STOP_TIME="${STOP_TIME:-6ms}"
CACHE_READ_PATH="${CACHE_READ_PATH:-1}"
# iter-24: CLK64_SDRAM=1 runs the dual-clock (faithful sdram_pm timing) proof.
# Default 0 = clk32 behavioral SDRAM (the green coherent baseline).
CLK64_SDRAM="${CLK64_SDRAM:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging_coh"
WORK_DIR="${SCRIPT_DIR}/work_coherency"

GHDL_FLAGS=(--std=08 --ieee=synopsys -frelaxed "--workdir=${WORK_DIR}")
GHDL="${GHDL:-ghdl}"

if ! command -v "${GHDL}" >/dev/null 2>&1; then
    echo "error: ghdl not on PATH (set GHDL=/path/to/ghdl)" >&2
    exit 2
fi

mkdir -p "${WORK_DIR}" "${STAGE}"

# --- Staging copy of fpga64_sid_iec.vhd + patches ---
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
# Patch #4 (iter-23): force scpu_rom_vis='0' at reset so the C64 KERNAL (our
# test ROM) is served at $E000-$FFFF. On real HW supercpu_rom_vis defaults '1'
# and the kickstart EPROM provides the reset vector + later clears rom_vis; the
# harness has no kickstart EPROM (scpuRomData empty) so $FFFC would read $00 ->
# PC=$0000. Forcing rom_vis='0' matches the steady-state Doom regime (rom_vis
# already cleared) where Bug 2 actually occurs. Sim-only; does not touch the
# cache logic. The 6-space gap before <= keeps this distinct from the $D0B6
# writer (scpu_rom_vis <= cpuDo(7)).
sed -i "s/scpu_rom_vis      <= '1';/scpu_rom_vis      <= '0';/" "${STAGE}/fpga64_sid_iec.vhd"

# Patch #3 (iter-23): flip CACHE_READ_PATH so the cache feeds the CPU.
if [ "${CACHE_READ_PATH}" == "1" ]; then
    sed -i 's/constant CACHE_READ_PATH : boolean := false;/constant CACHE_READ_PATH : boolean := true;/' "${STAGE}/fpga64_sid_iec.vhd"
    echo "patch#3: CACHE_READ_PATH=true"
else
    echo "patch#3: CACHE_READ_PATH left false (sanity run)"
fi

# Patch #5 (iter-24): stage the tb + flip DUALCLK for the dual-clock proof run.
cp -f "${SCRIPT_DIR}/c64_superram_coherency_tb.vhd" "${STAGE}/c64_superram_coherency_tb.vhd"
if [ "${CLK64_SDRAM}" == "1" ]; then
    sed -i 's/constant DUALCLK : boolean := false;/constant DUALCLK : boolean := true;/' "${STAGE}/c64_superram_coherency_tb.vhd"
    echo "patch#5: CLK64_SDRAM=1 (dual-clock proof; CPU expected to read stale)"
else
    echo "patch#5: CLK64_SDRAM=0 (clk32 coherent baseline)"
fi

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
    "${SCRIPT_DIR}/clk64_sdram_model.vhd"

    "${SCRIPT_DIR}/rom_loader_pkg.vhd"
    "${SCRIPT_DIR}/c64_reduced_top_v2.vhd"
    "${STAGE}/c64_superram_coherency_tb.vhd"
)

echo "==> Analyze (SuperRAM coherency repro, CACHE_READ_PATH=${CACHE_READ_PATH})"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_superram_coherency_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_superram_coherency_tb.log"
WAVE="${WORK_DIR}/c64_superram_coherency_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_superram_coherency_tb \
    --fst="${WAVE}" \
    --stop-time="${STOP_TIME}" \
    --ieee-asserts=disable \
    2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
set -e

echo ""
echo "log:  ${LOG}"
echo "wave: ${WAVE}"
echo "verdict:"
grep -E "SUPERRAM_COHERENCY:|HARNESS FAULT|SANITY:" "${LOG}" || true
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (ghdl -r exited ${RC})"
fi
exit "${RC}"
