-- reu_stub.vhd
--
-- Phase 4b: minimal VHDL stub for the reu.v Verilog module.
--
-- NOTE: the real reu.v is instantiated at the c64.sv level, NOT inside
-- fpga64_sid_iec.vhd. The Phase 4b harness instantiates fpga64_sid_iec
-- directly and therefore does NOT need a reu_stub to satisfy any
-- component binding. This stub exists only to document the interface so
-- a future Phase 4c harness that instantiates the whole c64.sv can
-- drop it in without re-reading the Verilog source.
--
-- Port list mirrors the module header in C64_MiSTer/rtl/reu.v:
--
--     module reu(
--         input             clk,
--         input             reset,
--         input             cpu_addr_hi,
--         input      [15:0] cpu_addr,
--         input             cpu_cs,    // fpga64 cpu_cs = iof_fall_pulse_r
--         input             cpu_we,
--         input       [7:0] cpu_di,
--         output reg  [7:0] cpu_do,
--         output reg        irq,
--         input       [7:0] dma_din,
--         output reg  [7:0] dma_dout,
--         output reg [24:0] dma_addr,
--         output reg        dma_we,
--         output reg        dma_req,
--         input             dma_cycle
--     );
--
-- The stub holds all outputs to their idle values (no DMA, no IRQ,
-- reads return $FF matching open-bus behaviour on the real chip).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reu is
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;
        cpu_addr    : in  unsigned(15 downto 0);
        cpu_cs      : in  std_logic;
        cpu_we      : in  std_logic;
        cpu_di      : in  unsigned(7 downto 0);
        cpu_do      : out unsigned(7 downto 0);
        irq         : out std_logic;
        dma_din     : in  unsigned(7 downto 0);
        dma_dout    : out unsigned(7 downto 0);
        dma_addr    : out unsigned(24 downto 0);
        dma_we      : out std_logic;
        dma_req     : out std_logic;
        dma_cycle   : in  std_logic
    );
end entity;

architecture stub of reu is
begin
    cpu_do   <= x"FF";
    irq      <= '0';
    dma_dout <= (others => '0');
    dma_addr <= (others => '0');
    dma_we   <= '0';
    dma_req  <= '0';
end architecture;
