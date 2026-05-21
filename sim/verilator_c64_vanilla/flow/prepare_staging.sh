#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERILATOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${VERILATOR_DIR}/../.." && pwd)"
RTL="${REPO_ROOT}/C64_MiSTer/rtl"
STAGE="${SCRIPT_DIR}/build_staging"

mkdir -p "${STAGE}"
cp -f "${RTL}/fpga64_sid_iec.vhd" "${STAGE}/fpga64_sid_iec.vhd"
cp -f "${RTL}/cpu_6510.vhd" "${STAGE}/cpu_6510.vhd"

# The fpga64_buslogic dprom instances reference "rtl/roms/*.mif" with paths
# relative to the ghdl --synth working directory. Expose them via an
# rtl/roms/ symlink so chargen, kernal and related ROM images load at
# synthesis time instead of defaulting to all-zero BRAM (which would make
# the VIC-II render blank character cells).
mkdir -p "${VERILATOR_DIR}/rtl"
ln -sfn "${RTL}/roms" "${VERILATOR_DIR}/rtl/roms"

python3 - "${STAGE}/fpga64_sid_iec.vhd" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
with p.open('r', newline='') as f:
    src = f.read()

old_case = 'when "11" => turbo_m <= "000"; -- 1x (C64 speed)'
new_case = old_case + '\n\t\t\t\t\t\t\twhen others => turbo_m <= "000";'
if old_case in src and 'when others => turbo_m <= "000";' not in src:
    src = src.replace(old_case, new_case, 1)

old_block = (
    "\tif rising_edge(clk32) then\n"
    "\t\tpreCycle <= sysCycleDef'succ(preCycle);\n"
    "\t\tif preCycle = sysCycleDef'high then\n"
    "\t\t\tpreCycle <= sysCycleDef'low;\n"
    "\t\t\tif sysEnable = '1' then\n"
    "\t\t\t\trfsh_cycle <= rfsh_cycle + 1;\n"
    "\t\t\tend if;\n"
    "\t\tend if;\n"
)
new_block = (
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
if old_block in src:
    src = src.replace(old_block, new_block, 1)

with p.open('w', newline='') as f:
    f.write(src)
print(f"Prepared staged fpga64_sid_iec.vhd at {p}")
PY

python3 - "${STAGE}/cpu_6510.vhd" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
with p.open('r', newline='') as f:
    src = f.read()

src = src.replace('cpu: work.T65', 'cpu: entity work.T65')

with p.open('w', newline='') as f:
    f.write(src)
print(f"Prepared staged cpu_6510.vhd at {p}")
PY
