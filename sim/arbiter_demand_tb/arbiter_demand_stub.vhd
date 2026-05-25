-- arbiter_demand_stub.vhd
--
-- Milestone C sketch: demand-driven CPU bus arbiter.
--
-- See docs/milestone_c_arbiter_design.md Section B for the architectural
-- contract. This file is the SKETCH entity — the real implementation
-- will live at C64_MiSTer/rtl/bus_arbiter_demand.vhd after the design
-- session opens. This stub exists only to validate the priority logic
-- in isolation via sim/arbiter_demand_tb/arbiter_demand_tb.vhd.
--
-- Priority: VIC > DMA > SDRAM-busy > CPU.
--
-- Grant equation (combinational):
--   cpu_grant <= cpu_req
--                AND NOT vic_active
--                AND NOT dma_active
--                AND NOT sdram_busy
--
-- The registered grant_d1 output is a one-clk delayed echo of cpu_grant,
-- exposed so future integration tests can verify that downstream
-- consumers (e.g. the bridge prefetch FSM) see exactly one pulse per
-- grant cycle. The clk-domain (clk_sys / clk32) and reset polarity
-- match fpga64_sid_iec.vhd conventions.

library IEEE;
use IEEE.std_logic_1164.all;

entity arbiter_demand_stub is
port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Wheel inputs (driven from sysCycle / DMA controller / SDRAM ctrl
    -- in the real instance).
    vic_active  : in  std_logic;
    dma_active  : in  std_logic;
    sdram_busy  : in  std_logic;

    -- CPU side.
    cpu_req     : in  std_logic;
    cpu_grant   : out std_logic;

    -- Debug: one-clk registered echo of cpu_grant.
    grant_d1    : out std_logic
);
end entity;

architecture rtl of arbiter_demand_stub is
    signal grant_comb : std_logic;
    signal grant_reg  : std_logic := '0';
begin

    -- Combinational priority logic.
    grant_comb <= cpu_req
                  and (not vic_active)
                  and (not dma_active)
                  and (not sdram_busy);

    cpu_grant <= grant_comb;

    -- Registered echo for downstream observability.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                grant_reg <= '0';
            else
                grant_reg <= grant_comb;
            end if;
        end if;
    end process;

    grant_d1 <= grant_reg;

end architecture;
