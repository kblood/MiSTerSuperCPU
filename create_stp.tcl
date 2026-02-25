# create_stp.tcl
# Reads found_nodes.txt (output of find_stp_nodes.tcl) and generates
# supercpu_debug.stp, then enables Signal Tap in the project.
#
# Usage (from C64_MiSTer/ directory):
#   wsl ~/intelFPGA_lite/22.1std.1/quartus/bin/quartus_sh -t ../create_stp.tcl

package require ::quartus::project
package require ::quartus::stp

set nodes_file "../found_nodes.txt"
set stp_out    "rtl/supercpu_debug.stp"
set depth      512
set clock_pat  "emu|fpga64|clk32"

# Read node list
if {![file exists $nodes_file]} {
    puts "ERROR: $nodes_file not found.  Run find_stp_nodes.tcl first."
    exit 1
}
set fh [open $nodes_file r]
set node_list [split [string trim [read $fh]] "\n"]
close $fh
puts "Loaded [llength $node_list] nodes from $nodes_file"

project_open C64

# Create the STP instance
stp_new
stp_set_global_signal -name "SAMPLE_CLOCK" -type "EQUAL" -value $clock_pat
stp_set_sampleconfig -depth $depth -trigger_in_enabled false

# Add each node
foreach n $node_list {
    set n [string trim $n]
    if {$n eq ""} continue
    puts "Adding: $n"
    if {[catch { stp_add_nodes $n } err]} {
        puts "  WARNING: $err"
    }
}

# Set trigger: capture when supercpu_en='1'
set trigger_node ""
foreach n $node_list {
    if {[string match "*supercpu_en*" $n] && ![string match "*816*" $n]} {
        set trigger_node $n
        break
    }
}
if {$trigger_node ne ""} {
    puts "Setting trigger on: $trigger_node"
    catch {
        stp_set_trigger_condition -instance_index 0 -type "OR"
        stp_set_trigger_node -instance_index 0 \
            -node_name $trigger_node -trigger_pattern "1"
    }
}

stp_save $stp_out
puts "Saved: $stp_out"

# Enable Signal Tap in project QSF
set_global_assignment -name ENABLE_SIGNALTAP ON
set_global_assignment -name USE_SIGNALTAP_FILE $stp_out
export_assignments
puts "Signal Tap enabled in C64.qsf"

project_close
puts "\nDone. Now rebuild: .\\build_c64.ps1 to embed Signal Tap logic."
