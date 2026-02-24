# signaltap_setup.tcl
# Run this with:  quartus_sh -t signaltap_setup.tcl
# from C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer
# It creates rtl/supercpu_debug.stp with the key SuperCPU debug signals,
# adds it to the project, and enables Signal Tap for the next full build.
#
# After running this, rebuild with build_c64.ps1 to embed the Signal Tap
# logic.  Then use launch_signaltap.ps1 to connect and capture.

package require ::quartus::project
package require ::quartus::stp

# --- configuration ---
set stp_file "rtl/supercpu_debug.stp"
set sample_depth 512
set clock_node  "emu|fpga64|clk32"

# Key signals to capture during SuperCPU boot
set capture_nodes {
    "emu|fpga64|cpuAddr"
    "emu|fpga64|addr_hi_816"
    "emu|fpga64|cpuDi"
    "emu|fpga64|cpuDo"
    "emu|fpga64|cpuWe"
    "emu|fpga64|enableCpu_816"
    "emu|fpga64|supercpu_en"
    "emu|fpga64|emu_mode_816"
    "emu|fpga64|buslogic|scpu_rom_en"
}

# --- setup ---
project_open C64

# Create the STP file
if {[file exists $stp_file]} {
    puts "Opening existing STP: $stp_file"
    stp_open $stp_file
} else {
    puts "Creating new STP: $stp_file"
    stp_new
}

# Delete existing instance if present
catch { stp_delete_instance "auto_signaltap_0" }

# Create instance
stp_set_global_signal -name "SAMPLE_CLOCK" -type "EQUAL" -value $clock_node

# Configure sample depth and trigger
stp_set_sampleconfig -depth $sample_depth -trigger_in_enabled false

# Add all capture nodes
foreach node $capture_nodes {
    if {[catch { stp_add_nodes $node } err]} {
        puts "WARNING: could not add node '$node': $err"
        puts "  (Run after synthesis so post-fit node names are available)"
    }
}

# Trigger on supercpu_en rising edge
catch {
    stp_set_trigger_condition -instance_index 0 -type "OR"
    stp_set_trigger_node -instance_index 0 \
        -node_name "emu|fpga64|supercpu_en" \
        -trigger_pattern "R"   ;# Rising edge
}

stp_save $stp_file
puts "Saved: $stp_file"

# Enable Signal Tap in the project
set_global_assignment -name ENABLE_SIGNALTAP ON
set_global_assignment -name USE_SIGNALTAP_FILE $stp_file
export_assignments

project_close
puts "Done.  Rebuild with build_c64.ps1 to embed Signal Tap logic."
