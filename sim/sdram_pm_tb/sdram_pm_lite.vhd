-- sdram_pm_lite.vhd
--
-- VHDL model of the *proposed* Build C sdram_pm controller. Models the
-- HIT/MISS FSM described in docs/milestone_a_buildc_design.md §2, with
-- the same timing as the Verilog target would have:
--
--   MISS: q runs 0..5 then wraps (6 clk64 / cycle, matching v6 shortcut)
--   HIT:  q runs 0..2 then wraps (3 clk64 / cycle, no ACT, sample at q=2)
--
-- HIT detection: a same-bank, same-row access after a prior access. Row
-- validity is invalidated by reset, refresh, or a different-row access
-- (which transitions back to MISS path that itself re-validates row).
--
-- This is NOT a port of sdram_pm.v — it's a behavioural model of the
-- *proposed* controller. The port set matches sdram_pm.v's relevant
-- signals so a later sim build can swap this for a real Verilog port,
-- but the implementation is intentionally minimal: just enough to drive
-- ready/data_valid at the right clk64 cycles and to expose the HIT
-- decision via a new dbg_hit_path output (used by the bench to verify
-- the FSM is taking the right branch).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_pm_lite is
    port (
        clk        : in  std_logic;                       -- 64 MHz domain
        reset      : in  std_logic;
        addr       : in  unsigned(24 downto 0);
        we         : in  std_logic;
        ce         : in  std_logic;
        refresh    : in  std_logic;
        ready      : out std_logic;
        data_valid : out std_logic;
        -- bench debug: 1 = current cycle is on the HIT (3-clk) fast path
        dbg_hit_path : out std_logic
    );
end entity;

architecture sim of sdram_pm_lite is

    -- Address slicing matches sdram_pm.v:185-188.
    function bank_of(a : unsigned(24 downto 0)) return unsigned is
    begin
        return a(22 downto 21);
    end function;

    function row_of(a : unsigned(24 downto 0)) return unsigned is
    begin
        return a(20 downto 8);
    end function;

    signal q              : unsigned(2 downto 0) := (others => '0');
    signal last_ce        : std_logic := '0';
    signal last_refresh   : std_logic := '0';

    signal last_bank      : unsigned(1 downto 0)  := (others => '0');
    signal last_row       : unsigned(12 downto 0) := (others => '0');
    signal last_row_valid : std_logic := '0';

    -- Current cycle's HIT/MISS decision, latched at the ce-edge.
    signal cycle_is_hit   : std_logic := '0';
    signal in_flight      : std_logic := '0';

    -- Per the design doc §2.2: MISS sample at q=5 (v6 shortcut), HIT sample
    -- at q=2. Ready rises one clk64 after sample (when q returns to 0).
    constant MISS_SAMPLE_Q : unsigned(2 downto 0) := "101";  -- q=5
    constant HIT_SAMPLE_Q  : unsigned(2 downto 0) := "010";  -- q=2

    signal ready_r       : std_logic := '1';
    signal data_valid_r  : std_logic := '0';
begin

    ready        <= ready_r;
    data_valid   <= data_valid_r;
    dbg_hit_path <= cycle_is_hit when in_flight = '1' else '0';

    process(clk)
        variable will_hit : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                q              <= (others => '0');
                last_ce        <= '0';
                last_refresh   <= '0';
                last_row_valid <= '0';
                last_bank      <= (others => '0');
                last_row       <= (others => '0');
                cycle_is_hit   <= '0';
                in_flight      <= '0';
                ready_r        <= '1';
                data_valid_r   <= '0';
            else
                last_ce      <= ce;
                last_refresh <= refresh;

                -- Refresh invalidates the open row.
                if refresh = '1' and last_refresh = '0' then
                    last_row_valid <= '0';
                end if;

                -- ce-edge launches a new cycle if controller is idle (q=0
                -- and ~in_flight). Subsequent ce-edges during in-flight
                -- are ignored — matches sdram_pm.v's first-edge-wins.
                if ce = '1' and last_ce = '0'
                   and in_flight = '0' and q = "000" then

                    -- Decide HIT vs MISS at the ce-edge.
                    if last_row_valid = '1'
                       and bank_of(addr) = last_bank
                       and row_of(addr)  = last_row then
                        will_hit := '1';
                    else
                        will_hit := '0';
                    end if;
                    cycle_is_hit <= will_hit;
                    in_flight    <= '1';
                    ready_r      <= '0';
                    data_valid_r <= '0';

                    q             <= "001";
                    -- Record row for next-access HIT detection. (Updated
                    -- at issue time, mirroring sdram_pm.v's behaviour of
                    -- latching bank/row at ce-edge regardless of HIT.)
                    last_bank      <= bank_of(addr);
                    last_row       <= row_of(addr);
                    last_row_valid <= '1';

                elsif in_flight = '1' then
                    -- Advance q.
                    if cycle_is_hit = '1' then
                        -- HIT path: q sequence 0 (issue) -> 1 -> 2 (sample) -> 0.
                        if q = HIT_SAMPLE_Q then
                            -- Sample edge.
                            data_valid_r <= '1';
                            q            <= "000";
                            ready_r      <= '1';
                            in_flight    <= '0';
                        else
                            q <= q + 1;
                        end if;
                    else
                        -- MISS path: q runs 0..5 (sample at 5) then wraps.
                        if q = MISS_SAMPLE_Q then
                            data_valid_r <= '1';
                            q            <= "000";
                            ready_r      <= '1';
                            in_flight    <= '0';
                        else
                            q <= q + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
