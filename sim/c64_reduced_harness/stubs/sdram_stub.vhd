-- sdram_stub.vhd
--
-- Phase 4b: VHDL wrapper around simple_sdram_model that exposes the
-- interface of sdram.v (from C64_MiSTer/rtl/sdram.v).
--
-- NOTE: this stub is NOT used by the Phase 4b top (c64_reduced_top_v2
-- drives fpga64_sid_iec.ramDin/ramAddr/ramDout directly via its own
-- instance of simple_sdram_model). The file exists so that a future
-- Phase 4c harness instantiating the whole c64.sv can bind it.
--
-- Real sdram.v top-level ports (from the module header):
--
--     module sdram(
--         input             init,
--         input             clk,
--         input             clkref,
--         inout      [15:0] SDRAM_DQ,
--         output     [12:0] SDRAM_A,
--         output     [1:0]  SDRAM_BA,
--         output            SDRAM_DQML,
--         output            SDRAM_DQMH,
--         output            SDRAM_nCS,
--         output            SDRAM_nWE,
--         output            SDRAM_nRAS,
--         output            SDRAM_nCAS,
--         output            SDRAM_CKE,
--         input      [24:0] addr,      // byte address
--         input      [7:0]  din,
--         output     [7:0]  dout,
--         output     [7:0]  dout_hi,
--         output     [7:0]  dout_lo,
--         output     [7:0]  dout_reu,
--         input             we,
--         input             ce,
--         input             bt
--     );
--
-- For Phase 4b we do not need the physical SDRAM pins — the wrapper
-- keeps them `open` / hard-wired and delegates the byte-level storage
-- to the simple_sdram_model.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram is
    port (
        init        : in  std_logic;
        clk         : in  std_logic;
        clkref      : in  std_logic;
        SDRAM_DQ    : inout std_logic_vector(15 downto 0);
        SDRAM_A     : out std_logic_vector(12 downto 0);
        SDRAM_BA    : out std_logic_vector(1 downto 0);
        SDRAM_DQML  : out std_logic;
        SDRAM_DQMH  : out std_logic;
        SDRAM_nCS   : out std_logic;
        SDRAM_nWE   : out std_logic;
        SDRAM_nRAS  : out std_logic;
        SDRAM_nCAS  : out std_logic;
        SDRAM_CKE   : out std_logic;

        addr        : in  unsigned(24 downto 0);
        din         : in  std_logic_vector(7 downto 0);
        dout        : out std_logic_vector(7 downto 0);
        dout_hi     : out std_logic_vector(7 downto 0);
        dout_lo     : out std_logic_vector(7 downto 0);
        dout_reu    : out std_logic_vector(7 downto 0);
        we          : in  std_logic;
        ce          : in  std_logic;
        bt          : in  std_logic
    );
end entity;

architecture stub of sdram is
    signal addr24       : unsigned(23 downto 0);
    signal dout_i       : std_logic_vector(7 downto 0);
    signal probe_dummy  : std_logic_vector(7 downto 0);
begin
    addr24 <= addr(23 downto 0);

    -- Tri-state pins not used
    SDRAM_DQ   <= (others => 'Z');
    SDRAM_A    <= (others => '0');
    SDRAM_BA   <= (others => '0');
    SDRAM_DQML <= '1';
    SDRAM_DQMH <= '1';
    SDRAM_nCS  <= '1';
    SDRAM_nWE  <= '1';
    SDRAM_nRAS <= '1';
    SDRAM_nCAS <= '1';
    SDRAM_CKE  <= '0';

    mem : entity work.simple_sdram_model
        generic map (
            MEM_BYTES => 16 * 1024 * 1024
        )
        port map (
            clk        => clk,
            reset      => init,
            addr       => addr24,
            din        => din,
            we         => we,
            re         => ce,
            dout       => dout_i,
            probe_addr => (others => '0'),
            probe_dout => probe_dummy
        );

    dout     <= dout_i;
    dout_hi  <= dout_i;
    dout_lo  <= dout_i;
    dout_reu <= dout_i;
end architecture;
