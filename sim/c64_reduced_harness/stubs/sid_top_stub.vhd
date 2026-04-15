-- sid_top_stub.vhd
--
-- Phase 4b: behavioral VHDL stub matching the interface of the SystemVerilog
-- sid_top.sv module that fpga64_sid_iec.vhd instantiates via `component sid_top`.
--
-- Port list reproduced EXACTLY from the `component sid_top` block in
-- C64_MiSTer/rtl/fpga64_sid_iec.vhd lines 602-636.
--
-- The stub:
--   * Returns $00 on all SID register reads (SID is write-mostly for most
--     games; BASIC/KERNAL never read from SID registers during boot).
--   * Produces silent audio output ($00000 on both channels).
--   * Ignores writes, potentiometer inputs, and the external-input bus.
--
-- This is enough to let fpga64_sid_iec.vhd instantiate cleanly and execute
-- the BASIC/KERNAL boot path. The SID is not on the critical-load path for
-- any of the Phase 4b scenarios.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sid_top is
    port (
        reset         : in  std_logic;
        clk           : in  std_logic;
        ce_1m         : in  std_logic;

        cs            : in  std_logic_vector(1 downto 0);
        we            : in  std_logic;
        addr          : in  unsigned(4 downto 0);
        data_in       : in  unsigned(7 downto 0);
        data_out      : out unsigned(7 downto 0);

        pot_x_l       : in  std_logic_vector(7 downto 0) := (others => '0');
        pot_y_l       : in  std_logic_vector(7 downto 0) := (others => '0');
        pot_x_r       : in  std_logic_vector(7 downto 0) := (others => '0');
        pot_y_r       : in  std_logic_vector(7 downto 0) := (others => '0');

        audio_l       : out std_logic_vector(17 downto 0);
        audio_r       : out std_logic_vector(17 downto 0);

        ext_in_l      : in  std_logic_vector(17 downto 0);
        ext_in_r      : in  std_logic_vector(17 downto 0);

        fc_offset_l   : in  std_logic_vector(12 downto 0);
        fc_offset_r   : in  std_logic_vector(12 downto 0);

        filter_en     : in  std_logic_vector(1 downto 0);
        mode          : in  std_logic_vector(1 downto 0);
        cfg           : in  std_logic_vector(3 downto 0);

        ld_clk        : in  std_logic;
        ld_addr       : in  std_logic_vector(11 downto 0);
        ld_data       : in  std_logic_vector(15 downto 0);
        ld_wr         : in  std_logic
    );
end entity;

architecture stub of sid_top is
begin
    data_out <= (others => '0');
    audio_l  <= (others => '0');
    audio_r  <= (others => '0');
end architecture;
