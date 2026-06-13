#!/usr/bin/env bash
# iter-27: build + run the SYSTEM-level INTERNAL_FAST_FIRE validation.
#
# Drives the REAL fpga64_sid_iec arbiter (where INTERNAL_FAST_FIRE lives) with
# the make_bug2_test_rom program through the real P65C816 + bus arb, and:
#   * checks the cpu_cyc-VDA/VPA invariant (no prefetch on internal cycles),
#   * counts internal fast-fires (lever engagement),
#   * measures clk32 ticks to a fixed op_count (the throughput metric),
#   * reads the witness bytes (functional regression vs the baseline arbiter).
#
#   FASTFIRE=0 ./run_internal_fastfire.sh   # baseline arbiter (A/B reference)
#   FASTFIRE=1 ./run_internal_fastfire.sh   # INTERNAL_FAST_FIRE=true
#
# Run both; diff the "FASTFIRE:" / "FASTFIRE_WITNESS:" lines. Grep "FASTFIRE"
# for the verdict. (Cache OFF + clk32 SDRAM baseline by default; DUALCLK wedges
# even the baseline CPU in zero-delay sim, so it is NOT used for this A/B.)

set -euo pipefail

STOP_TIME="${STOP_TIME:-6ms}"
# iter-27: FASTFIRE=1 flips INTERNAL_FAST_FIRE=true (staged fpga64) AND
# FASTFIRE_MODE=true (staged tb) in lockstep. Default 0 = baseline arbiter.
FASTFIRE="${FASTFIRE:-0}"
# Cache OFF by default for the fast-fire validation (a separate, HW-dead lever).
CACHE_READ_PATH="${CACHE_READ_PATH:-0}"
# iter-24: CLK64_SDRAM=1 runs the dual-clock (faithful sdram_pm timing) proof.
# Default 0 = clk32 behavioral SDRAM (the green coherent baseline).
CLK64_SDRAM="${CLK64_SDRAM:-0}"
# iter-24: FILL_STAGED=1 flips FILL_STAGED_TUPLE=true (the staged reg->reg fill).
# Sim cannot VALIDATE the fix (Bug 2 is a setup-time class, unreproducible in
# zero-delay RTL) — this only regression-checks the staged path stays coherent
# in the clk32 baseline. Default 0 = direct fill (shipped path).
FILL_STAGED="${FILL_STAGED:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL="${REPO_ROOT}/C64_MiSTer/rtl"
RTL816="${RTL}/65C816"
PHASE2_DIR="${REPO_ROOT}/sim/prg_loader_tb"
COMMON_DIR="${REPO_ROOT}/sim/common/memory_models"
STUBS="${SCRIPT_DIR}/stubs"
STAGE="${SCRIPT_DIR}/build_staging_ff"
WORK_DIR="${SCRIPT_DIR}/work_fastfire"

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

# Patch #6 (iter-24): flip FILL_STAGED_TUPLE for the staged reg->reg fill path.
if [ "${FILL_STAGED}" == "1" ]; then
    sed -i 's/constant FILL_STAGED_TUPLE : boolean := false;/constant FILL_STAGED_TUPLE : boolean := true;/' "${STAGE}/fpga64_sid_iec.vhd"
    echo "patch#6: FILL_STAGED_TUPLE=true (staged reg->reg fill)"
else
    echo "patch#6: FILL_STAGED_TUPLE left false (direct fill)"
fi

# Patch #7 (iter-27): flip INTERNAL_FAST_FIRE in the staged fpga64.
if [ "${FASTFIRE}" == "1" ]; then
    sed -i 's/constant INTERNAL_FAST_FIRE : boolean := false;/constant INTERNAL_FAST_FIRE : boolean := true;/' "${STAGE}/fpga64_sid_iec.vhd"
    if ! grep -q 'constant INTERNAL_FAST_FIRE : boolean := true;' "${STAGE}/fpga64_sid_iec.vhd"; then
        echo "patch#7 ERROR: INTERNAL_FAST_FIRE constant not found/flipped" >&2
        exit 3
    fi
    echo "patch#7: INTERNAL_FAST_FIRE=true (fast-fire arbiter under test)"
else
    echo "patch#7: INTERNAL_FAST_FIRE left false (baseline arbiter A/B reference)"
fi

# Patch #9 (iter-28): flip DEMAND_ARBITER in the staged fpga64 (Milestone C
# demand slots). DEMAND=1 enables the busy-gated intermediate CPU-region fires.
# Zero-delay bench can only confirm functional correctness + fire-rate increase
# (it CANNOT validate the setup-time class — STA+HW are the real gates).
DEMAND="${DEMAND:-0}"
if [ "${DEMAND}" == "1" ]; then
    sed -i 's/constant DEMAND_ARBITER : boolean := false;/constant DEMAND_ARBITER : boolean := true;/' "${STAGE}/fpga64_sid_iec.vhd"
    if ! grep -q 'constant DEMAND_ARBITER : boolean := true;' "${STAGE}/fpga64_sid_iec.vhd"; then
        echo "patch#9 ERROR: DEMAND_ARBITER constant not found/flipped" >&2
        exit 3
    fi
    echo "patch#9: DEMAND_ARBITER=true (Milestone C demand slots under test)"
else
    echo "patch#9: DEMAND_ARBITER left false (baseline arbiter)"
fi

# Patch #10 (iter-28): NOEARLYCLEAR=1 disables the sdram_ready early-clear of
# sdram_busy_cnt, forcing the static decrement ONLY. This empirically isolates
# the mechanism: with the early-clear gone, the busy reservation "011" must
# static-decrement over the full 4 clk32 (the HW floor, since on real silicon
# the V6 6-clk64 MISS + 2-FF ready sync makes the early-clear arrive too late
# to ever beat the static path). Predicts DEMAND=1 becomes byte-identical to
# baseline (4-apart) — proving the demand slots are busy-blocked on HW.
NOEARLYCLEAR="${NOEARLYCLEAR:-0}"
if [ "${NOEARLYCLEAR}" == "1" ]; then
    sed -i "s/if sdram_ready_sync(1) = '1' and sdram_ready_sync_prev = '0' then/if false then  -- NOEARLYCLEAR: static-decrement only/" "${STAGE}/fpga64_sid_iec.vhd"
    if ! grep -q 'NOEARLYCLEAR: static-decrement only' "${STAGE}/fpga64_sid_iec.vhd"; then
        echo "patch#10 ERROR: early-clear condition not found/patched" >&2
        exit 3
    fi
    echo "patch#10: NOEARLYCLEAR=1 (sdram_busy_cnt static-decrement only = HW floor)"
else
    echo "patch#10: early-clear left intact (zero-delay over-fire path)"
fi

# Patch #5 (iter-24): stage the tb + flip DUALCLK for the dual-clock proof run.
cp -f "${SCRIPT_DIR}/c64_internal_fastfire_tb.vhd" "${STAGE}/c64_internal_fastfire_tb.vhd"
if [ "${CLK64_SDRAM}" == "1" ]; then
    sed -i 's/constant DUALCLK : boolean := false;/constant DUALCLK : boolean := true;/' "${STAGE}/c64_internal_fastfire_tb.vhd"
    echo "patch#5: CLK64_SDRAM=1 (dual-clock proof; CPU expected to read stale)"
else
    echo "patch#5: CLK64_SDRAM=0 (clk32 coherent baseline)"
fi
# Patch #8 (iter-27): flip FASTFIRE_MODE in the staged tb in lockstep with #7
# (report-only; lets the log record which arbiter ran).
if [ "${FASTFIRE}" == "1" ]; then
    sed -i 's/constant FASTFIRE_MODE : boolean := false;/constant FASTFIRE_MODE : boolean := true;/' "${STAGE}/c64_internal_fastfire_tb.vhd"
    echo "patch#8: FASTFIRE_MODE=true (tb report flag)"
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
    "${STAGE}/c64_internal_fastfire_tb.vhd"
)

echo "==> Analyze (SuperRAM coherency repro, CACHE_READ_PATH=${CACHE_READ_PATH})"
for s in "${SOURCES[@]}"; do
    echo "    $s"
    "${GHDL}" -a "${GHDL_FLAGS[@]}" "$s"
done

echo "==> Elaborate"
"${GHDL}" -e "${GHDL_FLAGS[@]}" c64_internal_fastfire_tb

echo "==> Run (stop-time=${STOP_TIME})"
LOG="${WORK_DIR}/c64_internal_fastfire_tb.log"
WAVE="${WORK_DIR}/c64_internal_fastfire_tb.fst"
set +e
"${GHDL}" -r "${GHDL_FLAGS[@]}" c64_internal_fastfire_tb \
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
grep -E "FASTFIRE:|FASTFIRE_WITNESS:|FASTFIRE METRIC:|INVARIANT VIOLATION|HARNESS FAULT|SANITY:" "${LOG}" || true
if [ "${RC}" -eq 0 ]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (ghdl -r exited ${RC})"
fi
exit "${RC}"
