# cache_sta_probe.tcl — isolate the cache_di -> cpuDi -> P65C816 path on the
# already-fitted probe netlist and re-test it under a forced single-cycle budget.
# Answers: does the cache HIT feed close at 1 clk32 (31.25ns), or only under the
# blanket `set_multicycle_path -setup 2 -to {*P65C816:cpu|*}` (62.5ns)?

project_open C64
create_timing_netlist
read_sdc
update_timing_netlist

set cache_regs [get_registers -nowarn {*gen_read_path:read_path_cache*}]
set cpu_regs   [get_registers -nowarn {*P65C816:cpu|*}]

puts "==== cache reg count ===="
puts [get_collection_size $cache_regs]
puts "==== cpu reg count ===="
puts [get_collection_size $cpu_regs]

puts "==== (A) DEFAULT BUDGET: cache -> P65C816 worst setup paths (multicycle as-built) ===="
report_timing -from $cache_regs -to $cpu_regs -setup -npaths 8 -detail full_path -panel_name "cache_to_cpu_default"

puts "==== (B) FORCE SINGLE-CYCLE: override -setup 1 on cache -> P65C816, re-analyze ===="
set_multicycle_path -setup 1 -from $cache_regs -to $cpu_regs
set_multicycle_path -hold  0 -from $cache_regs -to $cpu_regs
update_timing_netlist
report_timing -from $cache_regs -to $cpu_regs -setup -npaths 1 -detail full_path -panel_name "cache_to_cpu_1cyc" -file "cache_1cyc_path.txt"

project_close
