# probe_hierarchy.tcl
# Probes the post-synthesis netlist to find actual hierarchy and signal names
package require ::quartus::project
package require ::quartus::report

project_open C64
load_report C64

puts "=== Top-level hierarchy nodes ==="
set col [get_names -filter "*" -node_type hierarchy -observable_type post_fitter]
set count 0
foreach_in_collection item $col {
    set name [get_name_info -info full_path $item]
    puts $name
    incr count
    if {$count >= 30} { puts "... (truncated)"; break }
}

puts "\n=== cpuAddr signals (any hierarchy) ==="
foreach obs_type {post_fitter post_synthesis post_asm} {
    set col [get_names -filter "*cpuAddr*" -observable_type $obs_type]
    set count 0
    foreach_in_collection item $col {
        set name [get_name_info -info full_path $item]
        puts "$obs_type: $name"
        incr count
    }
    if {$count > 0} break
}

puts "\n=== supercpu_en signals ==="
set col [get_names -filter "*supercpu*" -observable_type post_fitter]
foreach_in_collection item $col {
    puts [get_name_info -info full_path $item]
}

puts "\n=== addr_hi_816 signals ==="
set col [get_names -filter "*addr_hi*" -observable_type post_fitter]
foreach_in_collection item $col {
    puts [get_name_info -info full_path $item]
}

project_close
