# find_nodes.tcl - Find SuperCPU signal paths in compiled C64 design
package require ::quartus::project
package require ::quartus::report

# Open the project
project_open C64 -revision C64

# Load the post-fitting netlist for node name queries
load_report

# Search for key SuperCPU signals
set patterns {
    "*enableCpu_816*"
    "*cpuAddr_816*"
    "*addr_hi_816*"
    "*emu_mode_816*"
    "*cpuDi*"
    "*cpuWe_816*"
    "*scpu_rom_vis*"
    "*reset*"
    "*supercpu_en*"
    "*clk32*"
}

foreach pat $patterns {
    set nodes [get_nodes -type {reg comb} -filter $pat]
    if {[llength $nodes] > 0} {
        foreach n $nodes {
            puts "FOUND: $n"
        }
    }
}

unload_report
project_close
