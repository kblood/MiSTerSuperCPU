# k=1 fast-fire STA feasibility probe.
# Reports worst setup paths INTO P65C816 at the current (-setup 2) constraint.
# For each path, -setup 1 slack = (reported slack) - one clk32 period (~31.25ns).
# Classify by source: bram_q (c64.sv BRAM) and P65C816-internal are the paths
# that fire 1-apart at k=1; sdram_pm / SuperRAM paths stay 4-apart (irrelevant).
project_open C64 -revision C64
create_timing_netlist
read_sdc
update_timing_netlist

puts "=== clk periods ==="
report_clocks -file k1_clocks.rpt

puts "=== worst 40 setup paths INTO P65C816 (current -setup 2) ==="
report_timing -setup -to [get_registers {*P65C816:cpu|*}] \
    -npaths 40 -detail summary -file k1_p65_setup2_summary.rpt

puts "=== detailed worst 8 (full node path, to see sources) ==="
report_timing -setup -to [get_registers {*P65C816:cpu|*}] \
    -npaths 8 -detail full_path -file k1_p65_setup2_detail.rpt

puts "=== paths FROM the bank-00 BRAM (bram_q) into P65C816 ==="
report_timing -setup -from [get_registers {*bram_q*}] -to [get_registers {*P65C816:cpu|*}] \
    -npaths 12 -detail summary -file k1_bramq_to_p65.rpt

puts "=== P65C816-internal -> P65C816 (CPU state feedback) ==="
report_timing -setup -from [get_registers {*P65C816:cpu|*}] -to [get_registers {*P65C816:cpu|*}] \
    -npaths 12 -detail summary -file k1_p65_internal.rpt

project_close
