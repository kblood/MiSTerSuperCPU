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
                    -to   [get_registers {*sdram:sdram|sd_*}]
set_multicycle_path -hold 3 \
                    -from [get_registers {*P65C816:cpu|*}] \
                    -to   [get_registers {*sdram:sdram|sd_*}]
