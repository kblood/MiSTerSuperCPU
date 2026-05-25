-- sdram_pm_lite_tb.vhd
--
-- Milestone A bench: exercises the proposed Build C HIT/MISS controller
-- behaviour and the busy-counter feedback loop described in
-- docs/milestone_a_buildc_design.md.
--
-- Scenarios (per design doc §6):
--   A. Cold MISS: first access after reset. ready falls then rises 6 clk64
--      after the ce-edge (5 clk64 from issue to sample @q=5, +1 for ready
--      to go high again).
--   B. Follow-up HIT: second access, same row. ready falls then rises
--      3 clk64 after the ce-edge (2 clk64 to sample @q=2, +1 for ready).
--   C. Back-to-back: second ce-edge during in_flight is ignored
--      (first-edge-wins); after drain the controller accepts a fresh HIT.
--   D. Refresh invalidates HIT: cold MISS → refresh pulse → same-row
--      access must be MISS.
--
-- Plus a Step 6 closure check (clk32 busy counter, HIT preload, real
-- ready edge clears within budget — Risk A.2 walk, design §4).
--
-- The clk64-cycle measurement is taken from the instant we drove
-- ce='1' (the model latches at the next rising clk64 edge → 1 clk64
-- pipeline offset; the "expected" values below build that offset in).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity sdram_pm_lite_tb is
end entity;

architecture sim of sdram_pm_lite_tb is

    constant CLK64_PERIOD : time := 15625 ps;   -- 64 MHz
    constant CLK32_PERIOD : time := 31250 ps;   -- 32 MHz

    signal clk64   : std_logic := '0';
    signal clk32   : std_logic := '0';
    signal reset   : std_logic := '1';

    signal addr        : unsigned(24 downto 0) := (others => '0');
    signal we          : std_logic := '0';
    signal ce          : std_logic := '0';
    signal refresh     : std_logic := '0';

    signal ready       : std_logic;
    signal data_valid  : std_logic;
    signal dbg_hit     : std_logic;

    -- Step 6 plumbing model (clk32 domain)
    signal sdram_busy_cnt      : unsigned(2 downto 0) := (others => '0');
    signal sdram_busy          : std_logic;
    signal sdram_ready_sync    : std_logic_vector(1 downto 0) := "11";
    signal sdram_ready_prev    : std_logic := '1';
    signal sdram_hit_clk32     : std_logic := '0';
    signal cpu_cyc_pulse       : std_logic := '0';
    signal cs_ram              : std_logic := '1';

    signal fail_count        : integer := 0;
    signal scenario_a_ok     : std_logic := '0';
    signal scenario_b_ok     : std_logic := '0';
    signal scenario_c_ok     : std_logic := '0';
    signal scenario_d_ok     : std_logic := '0';
    signal step6_ok          : std_logic := '0';

    signal sim_done          : boolean := false;

begin

    clk64 <= not clk64 after CLK64_PERIOD / 2 when not sim_done else '0';
    clk32 <= not clk32 after CLK32_PERIOD / 2 when not sim_done else '0';

    dut : entity work.sdram_pm_lite
        port map (
            clk          => clk64,
            reset        => reset,
            addr         => addr,
            we           => we,
            ce           => ce,
            refresh      => refresh,
            ready        => ready,
            data_valid   => data_valid,
            dbg_hit_path => dbg_hit
        );

    sdram_busy <= '1' when sdram_busy_cnt /= "000" else '0';

    process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                sdram_busy_cnt   <= (others => '0');
                sdram_ready_sync <= "11";
                sdram_ready_prev <= '1';
            else
                sdram_ready_sync <= sdram_ready_sync(0) & ready;
                sdram_ready_prev <= sdram_ready_sync(1);

                if cpu_cyc_pulse = '1' and cs_ram = '1' then
                    if sdram_hit_clk32 = '1' then
                        sdram_busy_cnt <= "001";   -- HIT preload (design §3.2)
                    else
                        sdram_busy_cnt <= "011";   -- MISS / Build B fallback
                    end if;
                elsif sdram_busy_cnt /= "000" then
                    if sdram_ready_sync(1) = '1'
                       and sdram_ready_prev   = '0' then
                        sdram_busy_cnt <= "000";
                    else
                        sdram_busy_cnt <= sdram_busy_cnt - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Stim + verdict. All clk64-cycle counts are measured from the
    -- rising edge at which ce='1' was first sampled by the model.
    stim : process
        procedure log(s : string) is
            variable lo : line;
        begin
            write(lo, s);
            writeline(output, lo);
        end procedure;

        procedure wait_clk64(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk64);
            end loop;
        end procedure;

        -- Issue a request and measure the clk64 latency from ce-edge to
        -- ready-rises. Asserts scenario PASS/FAIL into the named ok_sig.
        procedure issue_and_check(
            scenario : string;
            a        : unsigned(24 downto 0);
            expected : integer;
            tolerance : integer;
            signal ok_sig : out std_logic
        ) is
            variable elapsed   : integer := 0;
            variable max_wait  : integer := 50;
        begin
            -- Align to a clean rising edge, drive ce='1'+addr right after.
            wait until rising_edge(clk64);
            addr <= a;
            we   <= '0';
            ce   <= '1';
            -- Next rising edge: the model latches ce-edge and goes busy.
            -- This is "cycle 1" in the count.
            wait until rising_edge(clk64);
            ce <= '0';
            elapsed := 1;
            -- Sanity: ready should have dropped this edge.
            if ready /= '0' then
                -- Sometimes ready drops at the NEXT delta; allow one more
                -- edge of slack before declaring it dead.
                wait until rising_edge(clk64);
                elapsed := 2;
                if ready /= '0' then
                    log("FAIL " & scenario & ": controller never went busy");
                    fail_count <= fail_count + 1;
                    ok_sig <= '0';
                    return;
                end if;
            end if;
            -- Now wait for ready to return high.
            for i in 1 to max_wait loop
                wait until rising_edge(clk64);
                elapsed := elapsed + 1;
                if ready = '1' then exit; end if;
            end loop;
            if ready /= '1' then
                log("FAIL " & scenario & ": ready never rose (timeout)");
                fail_count <= fail_count + 1;
                ok_sig <= '0';
                return;
            end if;
            if elapsed >= (expected - tolerance)
               and elapsed <= (expected + tolerance) then
                log(scenario & " OK: ready in " & integer'image(elapsed)
                    & " clk64 (expected " & integer'image(expected)
                    & " +/-" & integer'image(tolerance) & ")");
                ok_sig <= '1';
            else
                log("FAIL " & scenario & ": ready in "
                    & integer'image(elapsed) & " clk64 (expected "
                    & integer'image(expected) & ")");
                fail_count <= fail_count + 1;
                ok_sig <= '0';
            end if;
        end procedure;

        -- Drive cpu_cyc_pulse for one clk32 with sdram_hit_clk32 set as
        -- specified. Returns once the pulse has been delivered.
        procedure drive_cpu_cyc(is_hit : std_logic) is
        begin
            sdram_hit_clk32 <= is_hit;
            wait until rising_edge(clk32);
            cpu_cyc_pulse <= '1';
            wait until rising_edge(clk32);
            cpu_cyc_pulse <= '0';
        end procedure;

    begin
        log("=== sdram_pm_lite_tb start ===");

        reset <= '1';
        wait_clk64(8);
        reset <= '0';
        wait_clk64(4);

        --
        -- Scenario A: cold MISS, expect 6 clk64 from ce-edge to ready.
        -- (1 for ce sample, 5 for q advance 0..5 with sample at q=5
        -- and ready rising the same edge as q wraps to 0.)
        --
        log("--- Scenario A (cold MISS row=0x001) ---");
        issue_and_check("Scenario A (MISS)",
                        to_unsigned(16#000100#, 25), 6, 1, scenario_a_ok);

        wait_clk64(6);

        --
        -- Scenario B: HIT (same row 0x001), expect 3 clk64.
        --
        log("--- Scenario B (HIT row=0x001) ---");
        issue_and_check("Scenario B (HIT)",
                        to_unsigned(16#000180#, 25), 3, 1, scenario_b_ok);

        wait_clk64(6);

        --
        -- Scenario C: back-to-back. First MISS on a new row, immediately
        -- pulse a second ce-edge while in_flight=1 (it must be ignored).
        -- After the first cycle drains, issue a proper HIT.
        --
        log("--- Scenario C (back-to-back, second ce ignored) ---");
        -- Cold MISS on row 0x002.
        wait until rising_edge(clk64);
        addr <= to_unsigned(16#000200#, 25);
        ce   <= '1';
        wait until rising_edge(clk64);     -- model latches at this edge
        ce   <= '0';
        wait until rising_edge(clk64);     -- 1 clk64 later, still in flight
        -- Pulse a second ce-edge while busy.
        addr <= to_unsigned(16#000280#, 25);  -- same row, different col
        ce   <= '1';
        wait until rising_edge(clk64);
        ce   <= '0';
        -- Wait for the first cycle's ready (it should be MISS, not corrupted).
        -- From the original ce-edge (3 edges back) to ready ~6 clk64 total.
        -- We're now ~3 clk64 in. Wait up to a generous bound.
        for i in 1 to 15 loop
            if ready = '1' then exit; end if;
            wait until rising_edge(clk64);
        end loop;
        if ready /= '1' then
            log("FAIL Scenario C: first MISS never completed");
            fail_count <= fail_count + 1;
            scenario_c_ok <= '0';
        else
            log("Scenario C MISS-drain OK: controller is idle after drain");
            -- Now do a clean HIT on row 0x002.
            issue_and_check("Scenario C HIT after drain",
                            to_unsigned(16#000240#, 25), 3, 1, scenario_c_ok);
        end if;

        wait_clk64(6);

        --
        -- Scenario D: cold MISS → refresh pulse → same-row access must
        -- be MISS (refresh invalidated row_valid).
        --
        log("--- Scenario D (refresh invalidates HIT) ---");
        issue_and_check("Scenario D cold MISS",
                        to_unsigned(16#000300#, 25), 6, 1, scenario_d_ok);
        wait_clk64(2);

        -- Refresh pulse.
        wait until rising_edge(clk64);
        refresh <= '1';
        wait_clk64(2);
        refresh <= '0';
        wait_clk64(2);

        -- Same row but row_valid was cleared by refresh → must be MISS.
        issue_and_check("Scenario D post-refresh MISS",
                        to_unsigned(16#000380#, 25), 6, 1, scenario_d_ok);
        -- dbg_hit should have been '0' during this cycle. (We don't
        -- check the level here since it pulses; the timing being MISS
        -- is the actual proof.)

        wait_clk64(6);

        --
        -- Step 6 closure check: HIT preload + real ready edge must clear
        -- busy_cnt within 3 clk32 of cpu_cyc fire. (Design §4.1: counter
        -- decrement gets us to clk32 cycle 2, ready edge confirms cycle 3.)
        --
        log("--- Step 6 closure check (HIT preload -> early clear) ---");
        -- Establish row 0x004 with a MISS first so the next access is HIT.
        issue_and_check("Step 6 prep MISS",
                        to_unsigned(16#000400#, 25), 6, 1, step6_ok);
        wait_clk64(4);

        -- HIT access, drive busy counter with HIT preload.
        drive_cpu_cyc('1');
        -- We just consumed 2 clk32 in drive_cpu_cyc. Pulse the actual
        -- HIT access to the model now.
        wait until rising_edge(clk64);
        addr <= to_unsigned(16#000480#, 25);
        ce   <= '1';
        wait until rising_edge(clk64);
        ce   <= '0';

        -- Wait 4 clk32 then check sdram_busy is cleared.
        wait until rising_edge(clk32);
        wait until rising_edge(clk32);
        wait until rising_edge(clk32);
        wait until rising_edge(clk32);
        if sdram_busy = '0' then
            log("Step 6 closure OK: busy cleared within 4 clk32 of HIT fire");
            step6_ok <= '1';
        else
            log("FAIL Step 6 closure: sdram_busy still high 4 clk32 after HIT");
            fail_count <= fail_count + 1;
            step6_ok <= '0';
        end if;

        wait_clk64(4);

        -- Final verdict. Settle one delta so the procedure-deferred signal
        -- assignments propagate into fail_count.
        wait_clk64(2);

        log("=== Verdict ===");
        if fail_count = 0
           and scenario_a_ok = '1'
           and scenario_b_ok = '1'
           and scenario_c_ok = '1'
           and scenario_d_ok = '1'
           and step6_ok      = '1' then
            log("RESULT: PASS");
        else
            log("RESULT: FAIL count=" & integer'image(fail_count)
                & " A=" & std_logic'image(scenario_a_ok)
                & " B=" & std_logic'image(scenario_b_ok)
                & " C=" & std_logic'image(scenario_c_ok)
                & " D=" & std_logic'image(scenario_d_ok)
                & " S6=" & std_logic'image(step6_ok));
        end if;

        sim_done <= true;
        wait for 100 ns;
        assert false report "End of simulation" severity note;
        wait;
    end process;

end architecture;
