#!/bin/bash
# Run Quartus STA against existing post-fit netlist with Option C SDC mod.
set -e
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
QUARTUS=$(ls -d $HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | grep -E "/17\." | tail -1)
if [ -z "$QUARTUS" ]; then
  QUARTUS=$(ls -d $HOME/intelFPGA_lite/*/quartus/bin 2>/dev/null | sort -V | tail -1)
fi
echo "Quartus: $QUARTUS"
echo "--- starting quartus_sta ---"
$QUARTUS/quartus_sta C64 2>&1 | tail -60
echo "--- sta done ---"
