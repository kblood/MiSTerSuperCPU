#!/bin/bash
cd /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer
export QUARTUS_ROOTDIR=/home/caldor/intelFPGA_lite/17.0/quartus
export PATH=$QUARTUS_ROOTDIR/bin:$PATH
quartus_sta -t report_timing.tcl 2>&1
