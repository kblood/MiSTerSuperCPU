-- clk64_sdram_model.vhd
--
-- iter-24: a clk64-clocked behavioral SDRAM that reproduces the TIMING of the
-- real sdram_pm.v (C64_MiSTer/rtl/sdram_pm.v) closely enough to expose cache
-- "Bug 2". The iter-23 harness clocked simple_sdram_model at clk32, which
-- COLLAPSED the clk64 SDRAM domain into clk32 and therefore could not produce
-- the clk64->clk32 CDC window that Bug 2 lives in:
--
--   * data_valid drops at the clk64 ce-edge (new cycle in flight)
--   * data_valid rises at q==STATE_READ (=5), 5 clk64 after the ce-edge,
--     the moment dout_r is sampled fresh
--   * the DUT syncs data_valid into clk32 with ONE flop, so at a clk32 consume
--     edge that lands just after a new read's clk64 ce-edge, data_valid_sync is
--     STILL HIGH from the PREVIOUS read -> the cache fill (gated on
--     data_valid_sync) fires against the not-yet-updated dout_r = the prior
--     read's byte = the stale fill that poisons the line (Bug 2).
--
-- This model mirrors sdram_pm.v's q state machine exactly (RASCAS_DELAY=2,
-- CAS_LATENCY=2 => STATE_READ=5, V6 early-exit q=5->0). ce is the clk32-rate
-- cycle-start strobe (held ~1 clk32 = 2 clk64), edge-detected here just like
-- the real `ce && !last_ce`. Writes take effect at the ce-edge (byte write).
--
-- Read latency: dout_r becomes fresh 5 clk64 (~2.5 clk32) after the ce-edge,
-- matching sdram_pm. dout is combinational off dout_r.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clk64_sdram_model is
    generic (
        MEM_BYTES : integer := 2 * 1024 * 1024
    );
    port (
        clk64 : in  std_logic;          -- 64 MHz SDRAM clock
        reset : in  std_logic;

        -- clk32-rate access interface (mirrors sdram_pm ce/we/addr/din)
        addr  : in  unsigned(23 downto 0);
        din   : in  std_logic_vector(7 downto 0);
        we    : in  std_logic;          -- write this cycle
        ce    : in  std_logic;          -- cycle-start strobe (clk32-rate, edge-detected)
        dout  : out std_logic_vector(7 downto 0);

        -- "dout_r is fresh" handshake, clk64-domain level (like sdram_pm)
        data_valid : out std_logic;

        -- combinational debug probe (sim-only, bypasses the pipeline)
        probe_addr : in  unsigned(23 downto 0);
        probe_dout : out std_logic_vector(7 downto 0)
    );
end entity;

architecture beh of clk64_sdram_model is

    type mem_t is array (0 to MEM_BYTES-1) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));

    -- sdram_pm q FSM constants
    constant STATE_READ : integer := 5;  -- STATE_CMD_CONT(2) + CAS_LATENCY(2) + 1

    signal q        : integer range 0 to 7 := 0;
    signal last_ce  : std_logic := '0';
    signal dout_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal cur_addr : unsigned(23 downto 0) := (others => '0');
    signal dv_i     : std_logic := '0';

    function safe_idx(a : unsigned(23 downto 0)) return integer is
        variable i : integer;
    begin
        i := to_integer(a);
        if i >= MEM_BYTES then
            return 0;
        else
            return i;
        end if;
    end function;

begin

    main : process(clk64)
    begin
        if rising_edge(clk64) then
            last_ce <= ce;

            if reset = '1' then
                q      <= 0;
                dv_i   <= '0';
                dout_r <= (others => '0');
            else
                -- Sample edge (sdram_pm: if q==STATE_READ -> dout_r<=sd_data,
                -- data_valid<=1). Mirrors the q==5 block.
                if q = STATE_READ then
                    dout_r <= mem(safe_idx(cur_addr));
                    dv_i   <= '1';
                end if;

                -- Cycle start on the ce rising edge (ce && !last_ce). Drops
                -- data_valid, captures the transaction, and (for a write) lands
                -- the byte. Takes priority over the q advance (a fresh ce edge
                -- never coincides with q==5 since a cycle is >=6 clk64 wide).
                if ce = '1' and last_ce = '0' then
                    q        <= 1;
                    dv_i     <= '0';
                    cur_addr <= addr;
                    if we = '1' then
                        mem(safe_idx(addr)) := din;
                    end if;
                elsif q /= 0 then
                    if q = STATE_READ then
                        q <= 0;          -- V6 early-exit (q=5 -> 0)
                    else
                        q <= q + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    dout       <= dout_r;
    data_valid <= dv_i;
    probe_dout <= mem(safe_idx(probe_addr));

end architecture;
