# Core-specific timing constraints for SuperCPU
# Supplements sys/sys_top.sdc
# NOTE: This file may be loaded before sys_top.sdc, so we must derive clocks first.

derive_pll_clocks
derive_clock_uncertainty

# clk32 (counter[2], ~32MHz) to clk64 (counter[1], ~64MHz) crossing:
# clk32 is derived from clk64 by /2 in the same PLL. Data launched by clk32
# is stable for 2 clk64 periods, so the destination has 2 cycles to capture.
# Without this, the analyzer assumes 1 clk64 period budget (~15.8ns), causing
# massive timing violations (-16ns slack on 443M paths).
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}] \
                    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
                    -setup 2

set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}] \
                    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
                    -hold 1

# clk64 (counter[1]) -> clk_sys (counter[2]) crossing — the REVERSE direction
# of the constraint above. SDRAM dout_r and related signals are registered on
# clk64 and consumed by the CPU on clk_sys. The CPU is gated by enableCpu
# which fires at most once per sysCycle (32 clk32 ticks = 16 clk64 ticks),
# so data registered on clk64 has many cycles to settle before being sampled.
# Without this, the analyzer assumed 1 clk_sys period budget; the worst path
# sdram.dout_r[8] -> P65C816.P[1] missed by -4.652ns in debug builds.
# Functional safety: SDRAM read SM takes ~5 clk32 ticks per access and CPU
# enable pulses are >= 4 clk32 ticks apart, so the 63.4ns multicycle budget
# is always met in real operation. Hold paths remain positive (+0.243ns min).
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
                    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}] \
                    -setup 2

set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
                    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}] \
                    -hold 1

# P65C816 CPU core uses clock-enable gating (CE from enableCpu_816).
# enableCpu_816 never fires on consecutive clk32 edges: BRAM/cache hits
# self-suppress for at least 1 cycle, SDRAM pipeline takes many cycles,
# and phantom enables fire once then suppress. All paths into P65C816
# registers have at least 2 clk32 periods to settle.
set_multicycle_path -setup 2 \
                    -to [get_registers {*P65C816:cpu|*}]
set_multicycle_path -hold 1 \
                    -to [get_registers {*P65C816:cpu|*}]

# P65C816 → sdram address path: sdram.v only captures sd_addr at the
# rising edge of `ce` (cart_ce → cpu_cyc), which fires at sysCycle CPU0/4/8/C
# — at minimum 4 clk32 cycles apart. The destination clk64 register is
# unconditional in HDL, so the timing analyzer assumes 1-2 clk64 edges
# of budget; in reality the address is only sampled when ce rises, giving
# many more cycles. The clk32→clk64 multicycle 2 above gives 31ns budget
# which is *just* missed (-0.118ns) by the MCode→sdram path through
# 15 levels of bus-mux logic. Bump to setup-4 for these specific paths
# (4 clk64 = 62.5ns budget) — still well under the actual functional
# minimum interval between ce pulses.
set_multicycle_path -setup 4 \
                    -from [get_registers {*P65C816:cpu|*}] \
                    -to   [get_registers {*sdram_pm:sdram|sd_*}]
set_multicycle_path -hold 3 \
                    -from [get_registers {*P65C816:cpu|*}] \
                    -to   [get_registers {*sdram_pm:sdram|sd_*}]

# Phase F.3 (2026-05-21) — scpu_async_bridge MCP / word-synchronizer CDC.
# Once clk_cpu is split off from clk_sys (c64.sv: wire clk_cpu = clk64),
# the bridge's req/ack toggle bits cross between counter[1] (clk64) and
# counter[2] (clk32) via dedicated 2-FF synchronizer chains, tagged with
# SYNCHRONIZER_IDENTIFICATION attributes inside scpu_async_bridge.vhd.
# This false-paths the synchronizer endpoints so TimeQuest doesn't try
# to time setup/hold across the asynchronous boundary. The existing
# multicycle constraints above remain authoritative for the non-bridge
# clk64<->clk32 paths (SDRAM dout, sd_addr).
#
# Refs: docs/hdl-coding-guidelines/{23-cdc-single-bit,24-cdc-multi-bit,
# 40-timing-closure-and-sdc}.md, docs/async_bridge_mcp_handshake_plan.md.
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_toggle_reg}] \
               -to   [get_registers {*scpu_async_bridge_inst|req_sync1_reg}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|bus_ack_toggle_reg}] \
               -to   [get_registers {*scpu_async_bridge_inst|ack_sync1_reg}]
# Payload bus from latched request regs to clk_sys-domain consumers:
# the payload is held stable for the entire round-trip (payload-stable-
# hold, doc 24 §3.3). Setup/hold on these paths is irrelevant; ack-toggle
# round-trip is the only sequencing.
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_addr_reg*}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_addr_hi_reg*}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_do_reg*}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_we_reg}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_vpa_reg}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
set_false_path -from [get_registers {*scpu_async_bridge_inst|cpu_req_vda_reg}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
# Reverse direction: bus_di_reg (clk_sys) -> bus_di_capture_reg (clk_cpu).
# bus_di_reg is held stable from the cycle the arbiter pulses
# bus_ack_pulse_in until the next request, so the clk_cpu capture is
# always reading a settled value.
set_false_path -from [get_registers {*scpu_async_bridge_inst|bus_di_reg*}] \
               -to   [get_registers {*scpu_async_bridge_inst|bus_di_capture_reg*}]
