# quartus_sta -t script: load post-fit netlist, report Option C worst paths.
# Assumes C64.sdc has been temporarily edited to drop the P65C816 mcp=2.
project_open C64
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_clock_fmax_summary -panel_name {fmax_optC}
report_timing -setup -npaths 30 -less_than_slack 0 \
              -panel_name {Setup_negative_paths} \
              -file output_files/optC_worst_setup.rpt
report_timing -setup -npaths 5 -detail full_path \
              -panel_name {Setup_worst_5_full} \
              -file output_files/optC_worst_5_detail.rpt
project_close
