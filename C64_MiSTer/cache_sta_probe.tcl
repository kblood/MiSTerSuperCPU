# cache_sta_probe.tcl — isolate the cache_di -> cpuDi -> P65C816 path on the
# already-fitted probe netlist and re-test it under a forced single-cycle budget.
# Answers: does the cache HIT feed close at 1 clk32 (31.25ns), or only under the
# blanket `set_multicycle_path -setup 2 -to {*P65C816:cpu|*}` (62.5ns)?

project_open C64
create_timing_netlist
read_sdc
update_timing_netlist

# iter-7d: the read-path override is now REGISTERED — the launch points of the
# cache->CPU path are the rp_cache_di_d1 / rp_cache_hit_d1 pipeline FFs (the
# cpu_cache instance internals tag_mem/line_word now feed ONLY those registers,
# a short intra-clk32 hop, not the CPU). So the from-set must include the d1
# registers, otherwise the probe reports the (now-cut) instance-internal paths
# and misses the real launch. Union: cpu_cache instance regs + the d1 override FFs.
set cache_regs [get_registers -nowarn {*gen_read_path:read_path_cache*}]
set d1_regs    [get_registers -nowarn {*rp_cache_di_d1*}]
set hit_regs   [get_registers -nowarn {*rp_cache_hit_d1*}]
set cache_regs [add_to_collection $cache_regs $d1_regs]
set cache_regs [add_to_collection $cache_regs $hit_regs]
set cpu_regs   [get_registers -nowarn {*P65C816:cpu|*}]

puts "==== cache reg count (incl rp_cache_*_d1) ===="
puts [get_collection_size $cache_regs]
puts "==== rp_cache_di_d1 count ===="
puts [get_collection_size $d1_regs]
puts "==== rp_cache_hit_d1 count ===="
puts [get_collection_size $hit_regs]
puts "==== cpu reg count ===="
puts [get_collection_size $cpu_regs]

puts "==== (A) DEFAULT BUDGET: cache -> P65C816 worst setup paths (multicycle as-built) ===="
report_timing -from $cache_regs -to $cpu_regs -setup -npaths 8 -detail full_path -panel_name "cache_to_cpu_default"

puts "==== (B) FORCE SINGLE-CYCLE: override -setup 1 on cache -> P65C816, re-analyze ===="
set_multicycle_path -setup 1 -from $cache_regs -to $cpu_regs
set_multicycle_path -hold  0 -from $cache_regs -to $cpu_regs
update_timing_netlist
report_timing -from $cache_regs -to $cpu_regs -setup -npaths 1 -detail full_path -panel_name "cache_to_cpu_1cyc" -file "cache_1cyc_path_iter7d.txt"

project_close
