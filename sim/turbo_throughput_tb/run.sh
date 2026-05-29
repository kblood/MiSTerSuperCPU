#!/usr/bin/env bash
# Two-domain throughput + correctness bench for the SuperCPU bus arbiter.
# Wires the real arbiter logic (cpu_arb_model, extracted from
# fpga64_sid_iec.vhd) on clk32 to the validated Build-C SDRAM model
# (sdram_pm_lite) on clk64, and measures effective MHz + stale-read count
# across the speed design space.
#
# Usage: ./run.sh            # runs the standard sweep
#        ./run.sh -gG_...    # run one custom config (passes args to ghdl -r)
set -e
cd "$(dirname "$0")"
mkdir -p work
ANALYZE=( "../sdram_pm_tb/sdram_pm_lite.vhd" "cpu_arb_model.vhd" "turbo_throughput_tb.vhd" )
for f in "${ANALYZE[@]}"; do
    ghdl -a --std=08 --work=work --workdir=work "$f"
done
ghdl -e --std=08 --work=work --workdir=work turbo_throughput_tb

run() { echo "=== $1 ==="; ghdl -r --std=08 --work=work --workdir=work turbo_throughput_tb $2 \
        2>&1 | grep -E "G_ALT|EFFECTIVE_MHZ|STALE_READS|CORRECTNESS|predicted_hits"; echo; }

if [ "$#" -gt 0 ]; then
    ghdl -r --std=08 --work=work --workdir=work turbo_throughput_tb "$@"
    exit 0
fi

echo "################ BASELINE / VALIDATION ################"
run "baseline: alt OFF, hit_mode=0 (= today's silicon)   " "-gG_STRIDE=1 -gG_US=2000"

echo "################ ALT-SLOTS x HIT-MODE (clean seq) ################"
run "alt ON, hit_mode=0 (no prediction -> no alt fire)   " "-gG_ALT_SLOTS=true -gG_HIT_MODE=0 -gG_STRIDE=1 -gG_US=2000"
run "alt ON, hit_mode=1 (PRIVATE predictor)              " "-gG_ALT_SLOTS=true -gG_HIT_MODE=1 -gG_STRIDE=1 -gG_US=2000"
run "alt ON, hit_mode=2 (SINGLE tracker) <-- the fix     " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_STRIDE=1 -gG_US=2000"

echo "################ ASYNC ROW-CLOSE STRESS (Doom REU hazard) ################"
run "mode=1 PRIVATE predictor, refresh=37 -> SHOULD FAIL " "-gG_ALT_SLOTS=true -gG_HIT_MODE=1 -gG_STRIDE=1 -gG_REFRESH_PERIOD=37 -gG_US=2000"
run "mode=2 SINGLE tracker,    refresh=37 -> SHOULD PASS " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_STRIDE=1 -gG_REFRESH_PERIOD=37 -gG_US=2000"

echo "################ TRUE-HANDSHAKE (iter-4's approach -> no gain) ################"
run "handshake busy<-synced data_valid                    " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_BUSY_FROM_READY=true -gG_STRIDE=1 -gG_US=2000"

echo "################ mode=2 HIT-RATE SENSITIVITY (graceful fallback) ################"
run "stride=64  (4 acc/page)                              " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_STRIDE=64  -gG_US=2000"
run "stride=128 (2 acc/page)                              " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_STRIDE=128 -gG_US=2000"
run "stride=256 (all miss -> baseline, no regression)     " "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_STRIDE=256 -gG_US=2000"

echo "################ INTERLEAVED (REAL Doom-loader / ZP-heavy shape, 2026-05-30) ################"
# odd accesses go to bank-$00 (fast_path=0) -> the controller's open SuperRAM row
# is a conflict-MISS on every return -> the page-mode HIT win EVAPORATES. This is
# the access shape of essentially all real C64/SCPU code (pervasive ZP/stack/KERNAL
# in bank-$00 interleaved with SuperRAM code/data). The headline 7.99 MHz above is
# a SEQUENTIAL-ONLY artifact; interleave is the realistic number.
run "mode=2 alt ON, INTERLEAVE  (~no gain vs 4.0 baseline)" "-gG_ALT_SLOTS=true -gG_HIT_MODE=2 -gG_INTERLEAVE=true -gG_US=2000"
run "mode=0 alt OFF, INTERLEAVE (= Build-1 HW config)     " "-gG_HIT_MODE=0 -gG_INTERLEAVE=true -gG_US=2000"
# NOTE: both report CORRECTNESS=PASS, but Build-1 BRK'd on HW. The stale monitor
# only catches premature NEXT-FIRE (new ce while ready=0); it does NOT model the
# real CPU consuming dout_r at a FIXED enableCpu edge (ungated by data_valid),
# which is how the q=7 conflict-MISS delivers stale data on silicon. Treat this
# bench as trustworthy for THROUGHPUT, NOT yet for the conflict-MISS correctness
# hazard. See docs/turbo_build1_controller_falsified.md.
