-- cpu_cache_fill_invalidate_race_tb.vhd — Bug 2, iter-22 hunt:
--   the IN-FLIGHT FILL vs CPU-WRITE/INVALIDATE ordering race.
--
-- GROUND TRUTH (the strongest HW signal we have). iter-18's on-silicon
-- divergence detector (CACHE_DATA_OVERRIDE=true + FILL_DATAVALID_GATE)
-- collapsed to just TWO residual mismatches, both of the form
--   bank $20  $00AE  cache=$00  SDRAM=$4A
-- i.e. the cache holds the EMPTY / pre-transfer value ($00) while SDRAM (the
-- truth) holds the loader's written byte ($4A). MEMORY.md flagged this as a
-- "second, distinct loader-WRITE -> fill-READ ORDERING race" — separate from
-- the cross-line HIT and from the fill-tuple skew (both already falsified on HW).
--
-- THE MECHANISM (why none of the existing benches catch it):
--   1. The CPU reads $20:00AE while SuperRAM there is still $00 (pre-transfer).
--      It MISSES (line not yet allocated) -> an SDRAM fill goes IN FLIGHT,
--      carrying the byte sampled at read-issue = the pre-write $00.
--   2. Before that fill lands, the loader long-stores $4A to $20:00AE.
--      cpu_we=1 fires invalidate_wr in cpu_cache — BUT the line for $00AE is
--      NOT yet tagged (the fill hasn't allocated it), so `tag_match=0` and the
--      invalidate is a NO-OP. The write itself reaches SDRAM (golden=$4A).
--   3. The in-flight fill finally lands and ALLOCATES the line with the stale
--      $00, valid=1. The line was never invalidated -> every later read HITs
--      and returns $00. Permanent corruption. (A cacheless CPU sees $00 once on
--      the early read, then $4A forever — fine. The cache makes $00 stick.)
--
-- The fix CANNOT live in cpu_cache: at write time there is no allocated line to
-- invalidate. It must CANCEL THE PENDING FILL in fpga64's rp_fill machinery when
-- a CPU write targets the in-flight fill address (clear rp_fill_req on a
-- matching cpuWe between rp_fill_we_imm and rp_fill_fire). This bench models
-- that rp_fill state machine at the TB level so the fix can be proven off-device
-- before touching fpga64_sid_iec.vhd.
--
-- SCENARIO BUG  (cancel disabled): reproduces cache=$00 vs golden=$4A.
-- SCENARIO FIX  (cancel enabled):  the pending fill is dropped; the re-read
--   MISSES (line never validated with stale data) so the CPU takes the SDRAM
--   path and sees the correct $4A.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_fill_invalidate_race_tb is
end entity;

architecture sim of cpu_cache_fill_invalidate_race_tb is
    constant CLK_PER : time := 31.25 ns; -- 32MHz

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal enable   : std_logic := '1';
    signal cpu_addr : unsigned(15 downto 0) := (others => '0');
    signal cpu_bank : unsigned(7 downto 0)  := (others => '0');
    signal cpu_we   : std_logic := '0';
    signal cpu_do   : unsigned(7 downto 0) := (others => '0');
    signal cache_di : unsigned(7 downto 0);
    signal cache_hit: std_logic;
    signal fill_data: unsigned(7 downto 0) := (others => '0');
    signal fill_we  : std_logic := '0';
    signal fill_addr: unsigned(15 downto 0) := (others => '0');
    signal fill_bank: unsigned(7 downto 0)  := (others => '0');
    signal snoop_we  : std_logic := '0';
    signal snoop_addr: unsigned(15 downto 0) := (others => '0');
    signal snoop_bank: unsigned(7 downto 0)  := (others => '0');
    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal wb_ack     : std_logic := '0';
    signal flush    : std_logic := '0';
    signal cpu_en   : std_logic := '0';
    signal same_line: std_logic;
    signal dbg_flush_active : std_logic;
    signal dbg_tag_match    : std_logic;

    signal test_done  : boolean := false;
    signal fail_count : integer := 0;

    -- The contended address: $20:00AE (the exact HW divergence-detector hit).
    constant A_ADDR : unsigned(15 downto 0) := x"00AE";
    constant A_BANK : unsigned(7 downto 0)  := x"20";
    constant PRE    : unsigned(7 downto 0)  := x"00";  -- pre-transfer (empty)
    constant POST   : unsigned(7 downto 0)  := x"4A";  -- loader-written truth

begin
    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PER/2;
            clk <= '1'; wait for CLK_PER/2;
        end loop;
        wait;
    end process;

    dut: entity work.cpu_cache
    port map (
        clk => clk, reset => reset, enable => enable,
        cpu_addr => cpu_addr, cpu_bank => cpu_bank, cpu_we => cpu_we, cpu_do => cpu_do,
        cache_di => cache_di, cache_hit => cache_hit,
        fill_data => fill_data, fill_we => fill_we, fill_addr => fill_addr, fill_bank => fill_bank,
        snoop_we => snoop_we, snoop_addr => snoop_addr, snoop_bank => snoop_bank,
        wb_pending => wb_pending, wb_addr => wb_addr, wb_data => wb_data, wb_ack => wb_ack,
        flush => flush, cpu_en => cpu_en, wb_enable => '0', same_line => same_line,
        dbg_flush_active => dbg_flush_active, dbg_tag_match => dbg_tag_match
    );

    stim: process
        -- Golden SDRAM truth for the contended byte.
        variable golden_a : unsigned(7 downto 0);

        -- TB model of fpga64's rp_fill state machine for the contended address.
        --   pend       = rp_fill_req  (a miss fill is in flight)
        --   pend_data  = the byte sampled at read-ISSUE (= cpuDi_nocache then)
        -- `cancel_en` = the proposed fix: clear pend on a CPU write to the
        --   pending fill address before the fill fires.
        -- `fails` accumulates stale-read detections (variable so the verdict
        --   logic below reads it immediately, no signal-update delta).
        procedure run_race(cancel_en : in boolean; tag : in string;
                           fails : inout integer) is
            variable pend      : std_logic := '0';
            variable pend_data : unsigned(7 downto 0) := (others => '0');
            variable got       : unsigned(7 downto 0);
            variable consumed  : unsigned(7 downto 0);
        begin
            -- clean slate
            flush <= '1'; wait for 2 * CLK_PER; flush <= '0';
            for i in 0 to 1040 loop wait until rising_edge(clk); end loop;
            golden_a := PRE;                       -- SuperRAM still empty

            ------------------------------------------------------------------
            -- (1) CPU read $20:00AE -> MISS while the line is empty.
            -- An SDRAM fill goes in flight carrying the byte sampled NOW = $00.
            ------------------------------------------------------------------
            cpu_addr <= A_ADDR; cpu_bank <= A_BANK; cpu_we <= '0';
            wait until rising_edge(clk); wait until rising_edge(clk);
            assert cache_hit = '0'
                report tag & " setup ERROR: line unexpectedly cached before fill"
                severity warning;
            pend      := '1';
            pend_data := golden_a;                 -- = $00, the pre-write byte

            ------------------------------------------------------------------
            -- (2) Loader long-stores $4A to $20:00AE (writes SDRAM = truth)
            -- while the fill is still in flight. cpu_we=1 -> invalidate_wr, but
            -- the line is not yet tagged for $00AE so tag_match=0 = NO-OP.
            ------------------------------------------------------------------
            golden_a := POST;                      -- SDRAM now holds $4A
            cpu_addr <= A_ADDR; cpu_bank <= A_BANK; cpu_we <= '1'; cpu_do <= POST;
            wait until rising_edge(clk); wait until rising_edge(clk);
            cpu_we <= '0'; cpu_do <= (others => '0');
            wait until rising_edge(clk);

            -- THE FIX: a CPU write to the pending fill address cancels it.
            if cancel_en and pend = '1' then
                pend := '0';
                report tag & " FIX: pending fill to $20:00AE CANCELLED by the write";
            end if;

            ------------------------------------------------------------------
            -- (3) The in-flight fill lands (if not cancelled), allocating the
            -- line with the STALE pre-write byte $00.
            ------------------------------------------------------------------
            if pend = '1' then
                fill_addr <= A_ADDR; fill_bank <= A_BANK; fill_data <= pend_data;
                fill_we <= '1';
                wait until rising_edge(clk);
                fill_we <= '0';
                wait until rising_edge(clk); wait until rising_edge(clk);
            end if;

            ------------------------------------------------------------------
            -- (4) CPU re-reads $20:00AE. consumed = hit ? cache : SDRAM(golden).
            ------------------------------------------------------------------
            cpu_addr <= A_ADDR; cpu_bank <= A_BANK; cpu_we <= '0';
            wait until rising_edge(clk); wait until rising_edge(clk);
            got := cache_di;
            if cache_hit = '1' then
                consumed := got;                    -- override would deliver this
            else
                consumed := golden_a;               -- miss -> SDRAM path = truth
            end if;

            report tag & " re-read $20:00AE: hit=" & std_logic'image(cache_hit)
                 & " cache=" & to_hstring(got)
                 & " golden=" & to_hstring(golden_a)
                 & " consumed=" & to_hstring(consumed);

            if consumed /= golden_a then
                report "  *** STALE: consumed " & to_hstring(consumed)
                     & " but SDRAM truth is " & to_hstring(golden_a)
                     & " (Bug-2 fill/invalidate race) ***" severity warning;
                fails := fails + 1;
                fail_count <= fail_count + 1;
            end if;
        end procedure;

        variable v_fails   : integer := 0;
        variable bug_fails : integer := 0;
        variable fix_fails : integer := 0;
    begin
        reset <= '1'; wait for 5 * CLK_PER; reset <= '0';

        report "=== SCENARIO BUG: in-flight fill NOT cancelled by the write ===";
        run_race(false, "BUG", v_fails);
        bug_fails := v_fails;
        if bug_fails > 0 then
            report "  BUG REPRODUCED: cache serves the pre-write $00 forever while"
                 & " SDRAM holds $4A = the exact iter-18 HW divergence signature.";
        else
            report "  BUG did NOT reproduce - the race model is wrong; re-examine."
                 severity warning;
        end if;

        report "=== SCENARIO FIX: cancel the pending fill on a matching write ===";
        run_race(true, "FIX", v_fails);
        fix_fails := v_fails - bug_fails;
        if fix_fails = 0 then
            report "  FIX HOLDS: cancelling the in-flight fill leaves the line"
                 & " invalid -> the re-read takes the SDRAM path and sees $4A.";
        else
            report "  FIX FAILED: still stale after cancel - fix is insufficient."
                 severity warning;
        end if;

        report "=== fails: BUG=" & integer'image(bug_fails)
             & " FIX=" & integer'image(fix_fails)
             & " (expect BUG=1, FIX=0) ===";
        if bug_fails = 0 then
            report "=== INCONCLUSIVE: bug did not reproduce ===" severity failure;
        elsif fix_fails /= 0 then
            report "=== FIX REGRESSION ===" severity failure;
        else
            report "=== DONE: bug reproduced AND fix proven ===";
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
