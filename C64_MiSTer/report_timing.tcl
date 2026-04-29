project_open C64

create_timing_netlist -model slow
read_sdc
update_timing_netlist

set clk32 {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}
set clk64 {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}

puts "\n=== TOP 10 GLOBAL WORST SETUP PATHS ==="
set paths [get_timing_paths -setup -npaths 10]
foreach_in_collection path $paths {
    set slack [get_path_info $path -slack]
    set from_name [get_node_info -name [get_path_info $path -from]]
    set to_name [get_node_info -name [get_path_info $path -to]]
    set from_clk [get_clock_info -name [get_path_info $path -from_clock]]
    set to_clk [get_clock_info -name [get_path_info $path -to_clock]]
    set levels [get_path_info $path -num_logic_levels]
    puts "Slack: $slack  Lev: $levels"
    puts "  $from_clk -> $to_clk"
    puts "  From: $from_name"
    puts "  To:   $to_name"
}

puts "\n=== TOP 5 WORST HOLD PATHS ==="
set hpaths [get_timing_paths -hold -npaths 5]
foreach_in_collection path $hpaths {
    set slack [get_path_info $path -slack]
    set from_name [get_node_info -name [get_path_info $path -from]]
    set to_name [get_node_info -name [get_path_info $path -to]]
    set from_clk [get_clock_info -name [get_path_info $path -from_clock]]
    set to_clk [get_clock_info -name [get_path_info $path -to_clock]]
    puts "Slack: $slack"
    puts "  $from_clk -> $to_clk"
    puts "  From: $from_name"
    puts "  To:   $to_name"
}

puts "\n=== TOP 5 clk32->clk32 INTERNAL WORST ==="
set c32p [get_timing_paths -from_clock $clk32 -to_clock $clk32 -setup -npaths 5]
foreach_in_collection path $c32p {
    set slack [get_path_info $path -slack]
    set from_name [get_node_info -name [get_path_info $path -from]]
    set to_name [get_node_info -name [get_path_info $path -to]]
    set levels [get_path_info $path -num_logic_levels]
    puts "Slack: $slack  Lev: $levels"
    puts "  From: $from_name"
    puts "  To:   $to_name"
}

puts "\n=== DONE ==="
project_close
