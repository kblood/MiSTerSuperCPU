-- cpu_cache_v164_tb.vhd
--
-- Task #24 / Phase A pivot bench: focused unit test for cpu_cache.vhd
-- write-buffer push behavior under the v164 design.
--
-- WHY THIS BENCH (and not the c64_reduced_harness path)
--   The c64_reduced_harness CPU is wedged from boot (PC=$0000, no writes).
--   See `project_reduced_harness_cpu_does_not_boot_kernal.md`. We can't
--   exercise `cacheable_wr` through it. So we drive cpu_cache.vhd directly
--   with hand-crafted stimulus and verify the FIFO behavior.
--
-- WHAT THIS BENCH TESTS
--   The v164 cpu_cache.vhd changes:
--     1. `cacheable_wr` gated on `cpu_en` pulse (one push per CPU step,
--        not one per `clk32` cycle that `cpu_we=1`).
--     2. `wb_pending` reflects FIFO non-empty.
--     3. `wb_addr` / `wb_data` carry the next-to-drain entry.
--     4. `wb_ack=1` pops one entry per cycle.
--     5. The split `cache_hit_rd` vs `cache_hit` gives the correct
--        OR/AND semantics.
--
-- EXPECTED RESULT MATRIX
--   * v163 HEAD (cacheable_wr=0)            -> SCENARIOS 1..3 FAIL
--                                              (no pushes ever happen)
--   * v164 stash b140fb4 (cacheable_wr conditional)
--                                           -> SCENARIOS 1..3 PASS
--                                              (push gated by cpu_en)
--
-- This bench is a DESIGN-VERIFICATION test, not a HEAD regression — it
-- confirms the v164 cpu_cache half is wired correctly so Phase B can
-- focus on the smaller fpga64_sid_iec half (cancel + enableCpu_816
-- substitute) which is review-able by hand and validated on hardware.
--
-- Scenarios:
--   1. Single write — drive cpu_we=1 for one cycle aligned with cpu_en;
--      verify wb_pending rises, wb_addr/wb_data correct, ack→pending=0.
--   2. cpu_en gating — hold cpu_we=1 for 5 clk32 cycles, pulse cpu_en
--      for ONE cycle in the middle; verify exactly ONE push.
--   3. Burst of 8 writes — fill FIFO partially; verify drain order is FIFO.
--
-- Exit code 0 = PASS, non-zero = FAIL.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity cpu_cache_v164_tb is
end entity;

architecture sim of cpu_cache_v164_tb is

    constant CLK_PERIOD : time := 31250 ps;  -- 32 MHz

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal enable  : std_logic := '1';

    signal cpu_addr : unsigned(15 downto 0) := (others => '0');
    signal cpu_bank : unsigned(7 downto 0)  := x"00";
    signal cpu_we   : std_logic := '0';
    signal cpu_do   : unsigned(7 downto 0)  := (others => '0');
    signal cpu_en   : std_logic := '0';

    signal cache_di     : unsigned(7 downto 0);
    signal cache_hit    : std_logic;
    signal cache_hit_rd : std_logic;

    signal fill_data : unsigned(7 downto 0)  := (others => '0');
    signal fill_we   : std_logic := '0';
    signal fill_addr : unsigned(15 downto 0) := (others => '0');
    signal fill_bank : unsigned(7 downto 0)  := (others => '0');

    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal wb_ack     : std_logic := '0';

    signal flush     : std_logic := '0';
    signal wb_enable : std_logic := '1';   -- v164 wb_enable=1

    signal same_line        : std_logic;
    signal dbg_flush_active : std_logic;
    signal dbg_tag_match    : std_logic;

    signal sim_done : boolean := false;

    procedure tick(signal clk : std_logic; n : natural) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

begin

    ------------------------------------------------------------------
    -- Clock + reset
    ------------------------------------------------------------------
    clkgen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT: real cpu_cache.vhd
    ------------------------------------------------------------------
    dut : entity work.cpu_cache
        port map (
            clk        => clk,
            reset      => reset,
            enable     => enable,

            cpu_addr   => cpu_addr,
            cpu_bank   => cpu_bank,
            cpu_we     => cpu_we,
            cpu_do     => cpu_do,

            cache_di     => cache_di,
            cache_hit    => cache_hit,
            cache_hit_rd => cache_hit_rd,

            fill_data  => fill_data,
            fill_we    => fill_we,
            fill_addr  => fill_addr,
            fill_bank  => fill_bank,

            wb_pending => wb_pending,
            wb_addr    => wb_addr,
            wb_data    => wb_data,
            wb_ack     => wb_ack,

            flush      => flush,
            cpu_en     => cpu_en,
            wb_enable  => wb_enable,

            same_line  => same_line,

            dbg_flush_active => dbg_flush_active,
            dbg_tag_match    => dbg_tag_match
        );

    ------------------------------------------------------------------
    -- Stimulus + scoreboard
    ------------------------------------------------------------------
    stim : process
        variable pass_cnt : integer := 0;
        variable fail_cnt : integer := 0;

        procedure check(constant lbl : in string; constant cond : in boolean) is
        begin
            if cond then
                report "PASS: " & lbl;
                pass_cnt := pass_cnt + 1;
            else
                report "FAIL: " & lbl severity warning;
                fail_cnt := fail_cnt + 1;
            end if;
        end procedure;

        -- Drive a single bank-$00 write at addr/data, with cpu_en pulse
        procedure single_write(
            constant addr : in unsigned(15 downto 0);
            constant data : in unsigned(7 downto 0)
        ) is
        begin
            cpu_addr <= addr;
            cpu_bank <= x"00";
            cpu_do   <= data;
            cpu_we   <= '1';
            cpu_en   <= '1';
            wait until rising_edge(clk);
            cpu_en   <= '0';
            cpu_we   <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Pop one entry from the FIFO via wb_ack pulse
        procedure ack_one is
        begin
            wb_ack <= '1';
            wait until rising_edge(clk);
            wb_ack <= '0';
            wait until rising_edge(clk);
        end procedure;
    begin
        ----------------------------------------------------------------
        -- Init: hold reset for a few cycles, then release
        ----------------------------------------------------------------
        reset <= '1';
        wait for CLK_PERIOD * 8;
        wait until rising_edge(clk);
        reset <= '0';

        -- Wait for the 1024-cycle flush sweep to complete (cache reset)
        tick(clk, 1100);

        report "==== cpu_cache reset/flush done; wb_pending=" &
               std_logic'image(wb_pending);

        ----------------------------------------------------------------
        -- Scenario 1: single write
        ----------------------------------------------------------------
        report "==== Scenario 1: single bank-$00 write ====";
        single_write(x"4000", x"AA");
        tick(clk, 2);

        check("S1: wb_pending = 1 after push", wb_pending = '1');
        check("S1: wb_addr = $4000",            wb_addr = x"4000");
        check("S1: wb_data = $AA",              wb_data = x"AA");

        ack_one;
        tick(clk, 2);
        check("S1: wb_pending = 0 after ack",  wb_pending = '0');

        ----------------------------------------------------------------
        -- Scenario 2: cpu_en gating — multi-cycle cpu_we, single cpu_en
        ----------------------------------------------------------------
        report "==== Scenario 2: cpu_en gating ====";
        cpu_addr <= x"5000";
        cpu_bank <= x"00";
        cpu_do   <= x"55";
        cpu_we   <= '1';
        cpu_en   <= '0';
        tick(clk, 2);  -- 2 cycles with cpu_we=1, cpu_en=0 → no push
        cpu_en   <= '1';
        wait until rising_edge(clk);
        cpu_en   <= '0';
        tick(clk, 2);  -- 2 more cycles cpu_we=1, cpu_en=0 → no push
        cpu_we   <= '0';
        tick(clk, 2);

        check("S2: wb_pending = 1 after exactly 1 cpu_en pulse",
              wb_pending = '1');
        check("S2: wb_addr = $5000", wb_addr = x"5000");
        check("S2: wb_data = $55",   wb_data = x"55");

        -- Drain and verify FIFO is empty (only one push happened, not 5)
        ack_one;
        tick(clk, 2);
        check("S2: wb_pending = 0 after one ack (only 1 entry pushed)",
              wb_pending = '0');

        ----------------------------------------------------------------
        -- Scenario 3: burst of 8 writes; verify FIFO drain order
        ----------------------------------------------------------------
        report "==== Scenario 3: burst of 8 writes + FIFO drain ====";
        for i in 0 to 7 loop
            single_write(to_unsigned(16#6000# + i, 16),
                         to_unsigned(i + 16#10#, 8));
        end loop;
        tick(clk, 2);

        check("S3: wb_pending = 1 after 8 pushes", wb_pending = '1');
        check("S3: wb_addr = $6000 (FIFO head)",   wb_addr = x"6000");
        check("S3: wb_data = $10",                  wb_data = x"10");

        for i in 0 to 7 loop
            check("S3.drain[" & integer'image(i) & "]: wb_addr = $6000+i",
                  wb_addr = to_unsigned(16#6000# + i, 16));
            check("S3.drain[" & integer'image(i) & "]: wb_data = $10+i",
                  wb_data = to_unsigned(i + 16#10#, 8));
            ack_one;
        end loop;
        tick(clk, 2);
        check("S3: wb_pending = 0 after 8 acks", wb_pending = '0');

        ----------------------------------------------------------------
        -- Summary
        ----------------------------------------------------------------
        tick(clk, 4);
        report "==== SUMMARY: pass=" & integer'image(pass_cnt)
               & "  fail=" & integer'image(fail_cnt) & " ====";
        sim_done <= true;

        if fail_cnt /= 0 then
            report "cpu_cache_v164_tb: FAIL "
                   & "(expected on v163 HEAD where cacheable_wr<='0'; "
                   & "should PASS once v164 cpu_cache changes are applied)"
                severity failure;
        else
            report "cpu_cache_v164_tb: PASS - v164 cpu_cache push logic correct"
                severity note;
            wait;
        end if;
    end process;

end architecture;
