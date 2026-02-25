# find_stp_nodes.tcl
# Run after a full compilation to find exact post-synthesis signal names
# Usage (from C64_MiSTer/ directory):
#   wsl ~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh -t ../find_stp_nodes.tcl
# Output: prints resolved node names, writes found_nodes.txt

package require ::quartus::project
package require ::quartus::report

project_open C64
load_report C64

puts "=== Searching for SuperCPU debug nodes ==="

set patterns {
    "emu|fpga64|cpuAddr*"
    "emu|fpga64|addr_hi_816*"
    "emu|fpga64|cpuDi*"
    "emu|fpga64|cpuDo*"
    "emu|fpga64|cpuWe*"
    "emu|fpga64|enableCpu_816*"
    "emu|fpga64|supercpu_en*"
    "emu|fpga64|emu_mode_816*"
    "emu|fpga64|buslogic|scpu_rom_en*"
}

set found {}
foreach pat $patterns {
    set col [get_names -filter $pat -observable_type post_fitter]
    if {$col eq "" || [llength $col] == 0} {
        set col [get_names -filter $pat -observable_type post_synthesis]
    }
    set count 0
    foreach_in_collection item $col {
        set name [get_name_info -info full_path $item]
        puts "  FOUND: $name"
        lappend found $name
        incr count
    }
    if {$count == 0} {
        puts "  NOT FOUND: $pat"
    }
}

set fh [open "../found_nodes.txt" w]
foreach n $found { puts $fh $n }
close $fh
puts "\nWrote [llength $found] nodes to found_nodes.txt"

project_close
