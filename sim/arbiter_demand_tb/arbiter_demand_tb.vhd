-- arbiter_demand_tb.vhd
--
-- Self-checking GHDL bench for the Milestone C demand-driven arbiter
-- sketch (arbiter_demand_stub.vhd). Validates the priority logic in
-- isolation: no bridge, no SDRAM model, no CPU instance.
--
-- Scenarios (per docs/milestone_c_arbiter_design.md §G.1):
--   T1  idle baseline                            -> grant=0
--   T2  CPU req alone                            -> grant=1
--   T3  CPU req + VIC active                     -> grant=0
--   T4  CPU req + DMA active                     -> grant=0
--   T5  CPU req + SDRAM busy                     -> grant=0
--   T6  CPU req, blocker drops, recovery in 1 clk
--   T7  All three blockers asserted              -> grant=0
--   T8  registered grant_d1 lags cpu_grant by 1 clk
--
-- Exit code 0 = PASS. Asserts (severity failure) fire on first mismatch.

library IEEE;
use IEEE.std_logic_1164.all;
use std.textio.all;

entity arbiter_demand_tb is
end entity;

architecture sim of arbiter_demand_tb is

    constant CLK_PERIOD : time := 31.25 ns;   -- 32 MHz clk32

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';

    signal vic_active  : std_logic := '0';
    signal dma_active  : std_logic := '0';
    signal sdram_busy  : std_logic := '0';
    signal cpu_req     : std_logic := '0';
    signal cpu_grant   : std_logic;
    signal grant_d1    : std_logic;

    signal sim_done    : boolean := false;
    signal fail_count  : natural := 0;

    -- helper: report + bump fail counter (don't kill sim on first fail
    -- so the log shows all failures in one run).
    procedure check(test : in string; got : in std_logic; want : in std_logic;
                    signal fc : inout natural) is
        variable l : line;
    begin
        if got = want then
            write(l, string'("  PASS: " & test));
            writeline(output, l);
        else
            write(l, string'("  FAIL: " & test & " got="));
            write(l, std_logic'image(got));
            write(l, string'(" want="));
            write(l, std_logic'image(want));
            writeline(output, l);
            fc <= fc + 1;
        end if;
    end procedure;

begin

    -- Clock
    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT
    dut : entity work.arbiter_demand_stub
    port map (
        clk        => clk,
        reset      => reset,
        vic_active => vic_active,
        dma_active => dma_active,
        sdram_busy => sdram_busy,
        cpu_req    => cpu_req,
        cpu_grant  => cpu_grant,
        grant_d1   => grant_d1
    );

    -- Driver / checker
    stim : process
        variable l : line;
    begin
        write(l, string'("==> arbiter_demand_tb start"));
        writeline(output, l);

        -- reset
        reset      <= '1';
        vic_active <= '0';
        dma_active <= '0';
        sdram_busy <= '0';
        cpu_req    <= '0';
        wait for 4 * CLK_PERIOD;
        reset <= '0';
        wait for 2 * CLK_PERIOD;

        ------------------------------------------------------------------
        -- T1: idle baseline
        ------------------------------------------------------------------
        write(l, string'("T1: idle baseline (nothing requested)"));
        writeline(output, l);
        wait for CLK_PERIOD;
        check("T1.grant=0", cpu_grant, '0', fail_count);

        ------------------------------------------------------------------
        -- T2: CPU req alone -> grant
        ------------------------------------------------------------------
        write(l, string'("T2: CPU req alone, no blockers -> grant rises"));
        writeline(output, l);
        cpu_req <= '1';
        wait for CLK_PERIOD / 4;  -- combinational settle
        check("T2.grant=1", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T3: CPU req + VIC active -> blocked
        ------------------------------------------------------------------
        write(l, string'("T3: CPU req + VIC active -> blocked"));
        writeline(output, l);
        vic_active <= '1';
        wait for CLK_PERIOD / 4;
        check("T3.grant=0", cpu_grant, '0', fail_count);
        vic_active <= '0';
        wait for CLK_PERIOD / 4;
        check("T3.recover_grant=1", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T4: CPU req + DMA active -> blocked
        ------------------------------------------------------------------
        write(l, string'("T4: CPU req + DMA active -> blocked"));
        writeline(output, l);
        dma_active <= '1';
        wait for CLK_PERIOD / 4;
        check("T4.grant=0", cpu_grant, '0', fail_count);
        dma_active <= '0';
        wait for CLK_PERIOD / 4;
        check("T4.recover_grant=1", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T5: CPU req + SDRAM busy -> blocked
        ------------------------------------------------------------------
        write(l, string'("T5: CPU req + SDRAM busy -> blocked"));
        writeline(output, l);
        sdram_busy <= '1';
        wait for CLK_PERIOD / 4;
        check("T5.grant=0", cpu_grant, '0', fail_count);
        sdram_busy <= '0';
        wait for CLK_PERIOD / 4;
        check("T5.recover_grant=1", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T6: blocker drops mid-cycle, grant rises on next sample.
        --     Test: assert sdram_busy at the start of a clk, drop it
        --     halfway through, check that cpu_grant tracks
        --     combinationally (no register delay on grant_comb).
        ------------------------------------------------------------------
        write(l, string'("T6: blocker drop, grant tracks combinationally"));
        writeline(output, l);
        -- align to a clk edge
        wait until rising_edge(clk);
        sdram_busy <= '1';
        wait for CLK_PERIOD / 8;
        check("T6.blocked", cpu_grant, '0', fail_count);
        sdram_busy <= '0';
        wait for CLK_PERIOD / 8;
        check("T6.unblock_comb", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T7: all three blockers asserted
        ------------------------------------------------------------------
        write(l, string'("T7: all three blockers asserted -> grant=0"));
        writeline(output, l);
        vic_active <= '1';
        dma_active <= '1';
        sdram_busy <= '1';
        wait for CLK_PERIOD / 4;
        check("T7.grant=0", cpu_grant, '0', fail_count);
        -- drop only VIC and DMA, sdram still busy
        vic_active <= '0';
        dma_active <= '0';
        wait for CLK_PERIOD / 4;
        check("T7.still_blocked_by_sdram", cpu_grant, '0', fail_count);
        -- drop sdram, now grant
        sdram_busy <= '0';
        wait for CLK_PERIOD / 4;
        check("T7.all_clear_grant=1", cpu_grant, '1', fail_count);

        ------------------------------------------------------------------
        -- T8: grant_d1 is registered, lags cpu_grant by 1 clk.
        --     Drop cpu_req, check that grant clears combinationally
        --     while grant_d1 stays high for one more clk.
        ------------------------------------------------------------------
        write(l, string'("T8: grant_d1 registered, lags by 1 clk"));
        writeline(output, l);
        -- ensure baseline: cpu_req=1, no blockers, grant=1 for >1 clk
        cpu_req <= '1';
        vic_active <= '0';
        dma_active <= '0';
        sdram_busy <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check("T8.pre.grant=1", cpu_grant, '1', fail_count);
        check("T8.pre.d1=1",    grant_d1,  '1', fail_count);
        -- drop cpu_req synchronously to a clk edge, then sample shortly
        -- after: cpu_grant must drop immediately (combinational), but
        -- grant_d1 should still hold '1' from the previous edge.
        wait until rising_edge(clk);
        cpu_req <= '0';
        wait for CLK_PERIOD / 8;
        check("T8.grant_comb_drops", cpu_grant, '0', fail_count);
        check("T8.d1_still_high",    grant_d1,  '1', fail_count);
        -- after another clk edge, d1 follows
        wait until rising_edge(clk);
        wait for CLK_PERIOD / 8;
        check("T8.d1_drops_next_clk", grant_d1, '0', fail_count);

        ------------------------------------------------------------------
        -- Final report
        ------------------------------------------------------------------
        write(l, string'(""));
        writeline(output, l);
        if fail_count = 0 then
            write(l, string'("==> RESULT: PASS (all checks)"));
        else
            write(l, string'("==> RESULT: FAIL (" ));
            write(l, fail_count);
            write(l, string'(" check(s) failed)"));
        end if;
        writeline(output, l);

        sim_done <= true;
        wait for CLK_PERIOD;

        assert fail_count = 0
            report "arbiter_demand_tb FAILED"
            severity failure;

        wait;
    end process;

end architecture;
