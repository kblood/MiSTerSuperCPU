# signaltap_setup_win.tcl - Run with quartus_stp.exe -t (NOT quartus_sh)
# from C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer

package require ::quartus::project
package require ::quartus::stp

set stp_file "rtl/supercpu_debug.stp"
set sample_depth 2048

# Key signals
set capture_nodes {
    "emu|fpga64|cpuAddr"
    "emu|fpga64|addr_hi_816"
    "emu|fpga64|cpuDi"
    "emu|fpga64|cpuDo"
    "emu|fpga64|cpuWe"
    "emu|fpga64|enableCpu_816"
    "emu|fpga64|supercpu_en"
    "emu|fpga64|emu_mode_816"
    "emu|fpga64|scpu_rom_vis"
    "emu|fpga64|buslogic|scpu_rom_en"
}

project_open C64

# Create STP
stp_new
stp_set_global_signal -name "SAMPLE_CLOCK" -type "EQUAL" -value "emu|fpga64|clk32"
stp_set_sampleconfig -depth $sample_depth -trigger_in_enabled false

foreach node $capture_nodes {
    if {[catch { stp_add_nodes $node } err]} {
        puts "WARNING: $node : $err"
    } else {
        puts "Added: $node"
    }
}

# Trigger: first time enableCpu_816 fires (captures a burst of CPU bus activity)
catch {
    stp_set_trigger_condition -instance_index 0 -type "OR"
    stp_set_trigger_node -instance_index 0 \
        -node_name "emu|fpga64|enableCpu_816" \
        -trigger_pattern "1"
}

stp_save $stp_file
puts "Saved: $stp_file"

set_global_assignment -name ENABLE_SIGNALTAP ON
set_global_assignment -name USE_SIGNALTAP_FILE $stp_file
export_assignments

project_close
puts "\nDone. Now rebuild with build_c64.ps1"
