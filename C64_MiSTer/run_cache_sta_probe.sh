#!/usr/bin/env bash
# iter-7d: run the cache->P65C816 setup-1 STA probe on the fitted netlist via WSL
# Quartus. Run AFTER a CACHE_READ_PATH=true probe build (fitter must have placed
# the netlist). Reuses cache_sta_probe.tcl (now unions rp_cache_*_d1 into the
# from-set). Writes cache_1cyc_path_iter7d.txt; prints the worst setup-1 slack.
#
# GO/NO-GO: forced -setup 1 worst slack POSITIVE => the registered override killed
# the masked single-cycle violation (iter-6 was -0.651ns on the un-registered path).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # C64_MiSTer/
QBIN="/home/caldor/intelFPGA_lite/17.0/quartus/bin"
"${QBIN}/quartus_sta" -t cache_sta_probe.tcl 2>&1 | tee cache_sta_probe_iter7d.log
echo "============================================================"
echo "(A) as-built setup-2 worst slack:"
grep -E "cache_to_cpu_default|Worst case slack" cache_sta_probe_iter7d.log | head -4 || true
echo "(B) forced setup-1 result:"
grep -E "Worst case slack" cache_1cyc_path_iter7d.txt | head -2 || true
echo "reg counts:"; grep -A1 -E "cache reg count|rp_cache_di_d1 count|rp_cache_hit_d1 count" cache_sta_probe_iter7d.log || true
