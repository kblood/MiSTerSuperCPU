#!/bin/bash
set -e
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
QUARTUS=$(ls -d $HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | grep -E "/17\." | tail -1)
[ -z "$QUARTUS" ] && QUARTUS=$(ls -d $HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | tail -1)
echo "Quartus: $QUARTUS"
$QUARTUS/quartus_sta -t /mnt/c/LLM/C64/MiSTerSuperCPU/tools/sta_optionc_worstpaths.tcl 2>&1 | tail -30
echo "--- worst negative-slack paths ---"
[ -f output_files/optC_worst_setup.rpt ] && cat output_files/optC_worst_setup.rpt
