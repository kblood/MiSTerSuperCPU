# datapath_surgery_sta_probe.tcl — iter-31 speed (datapath surgery track).
# Fresh STA of the cadence-critical read path on the CURRENT build (post RTI +
# DP-indirect compat fixes), to find the cycle-preserving cut that buys the
# ~4.65 ns the 3-apart (SLOT3) cadence lacked (iter-19 baseline).
#
# Three reports:
#  (A) dout_r -> CPU, as-built multicycle: the real data-delay breakdown.
#  (B) dout_r -> CPU forced -setup 1: the 3-apart budget; slack toward 0 = win.
#  (C) ALL launch -> CPU forced -setup 1, npaths 20: ranks the worst in-core
#      paths so we see whether the BCD AddSub carry chain is still the floor and
#      exactly which registers/bits dominate (the surgery target).

project_open C64
create_timing_netlist
read_sdc
update_timing_netlist

set sdram_regs [get_registers -nowarn {*dout_r*}]
set cpu_regs   [get_registers -nowarn {*P65C816:cpu|*}]

puts "==== reg counts: dout_r=[get_collection_size $sdram_regs] cpu=[get_collection_size $cpu_regs] ===="

puts "==== (A) AS-BUILT: dout_r -> P65C816 worst setup (data-delay breakdown) ===="
report_timing -from $sdram_regs -to $cpu_regs -setup -npaths 6 -detail full_path \
    -file "datapath_A_asbuilt.txt"

puts "==== (B) FORCE -setup 1 (3-apart budget): dout_r -> P65C816 ===="
set_multicycle_path -setup 1 -from $sdram_regs -to $cpu_regs
set_multicycle_path -hold  0 -from $sdram_regs -to $cpu_regs
update_timing_netlist
report_timing -from $sdram_regs -to $cpu_regs -setup -npaths 6 -detail full_path \
    -file "datapath_B_3apart.txt"

puts "==== (C) FORCE -setup 1: ALL launch -> P65C816 (rank in-core floor) ===="
set_multicycle_path -setup 1 -to $cpu_regs
set_multicycle_path -hold  0 -to $cpu_regs
update_timing_netlist
report_timing -to $cpu_regs -setup -npaths 20 -detail full_path \
    -file "datapath_C_incore_floor.txt"

project_close
