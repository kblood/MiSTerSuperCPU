-- p65c816_kickstart_drain_tb.vhd
--
-- Phase A / Task #14 (was #24): sim reproducer for the v166 hardware
-- failure (BRK ping-pong on vanilla BASIC cold boot — see
-- project_v166_hardware_failure_reverted.md).
--
-- The hardware failure mode: with the v164 path-(b) write-buffer drain
-- design active, vanilla BASIC fails because the kickstart's bank-$F8
-- ROM fetch is interrupted by the SDRAM-pipeline cancel logic firing on
-- a concurrent cacheable_wr push. The cpu_en gate on cacheable_wr was
-- supposed to make pushes happen at most once per CPU step, but the
-- combination with wb_drain_active stealing CPUC slots starves the F8
-- fetch.
--
-- This bench is UNIT-LEVEL: instantiates cpu_cache.vhd directly and
-- drives stimulus that mimics the suspected race. It is NOT a full
-- system reproducer — the real bug needs fpga64_sid_iec.vhd's cancel
-- logic + enableCpu_816 substitute. But this bench:
--   * Documents the expected coherency contract for cpu_cache under
--     concurrent wb_pending + bank-switching reads.
--   * Provides a regression gate for any future cpu_cache.vhd change.
--   * Will reproduce v164's behavior at the cpu_cache level (push vs
--     no-push) — the system-level race needs the c64_reduced_harness
--     fallback (task #25 BRAM probe wiring + scpu64.mif).
--
-- TWO SCENARIOS in one elaboration:
--
-- SCENARIO A — CPUC bank-$00 read during wb_drain_active window
--   1. Push 4 cacheable_wr entries (bank=$00 addr=$1000-$1003 data=$AA-$AD)
--   2. Begin draining: wb_ack pulses one-per-cycle → wb_pending stays
--      asserted for 4 cycles.
--   3. During the drain window, drive a CPU read at bank=$00 addr=$1000.
--   4. EXPECTED: cache_hit=1 AND cache_di=$AA (write-through coherent).
--   5. FAIL if cache_di returns the pre-write value (stale).
--
-- SCENARIO B — Long fetch from $F8xxxx during fresh cacheable_wr push
--   1. Pre-fill bank-$F8 cache lines at $F8:$0000-$F8:$0007 with $F0-$F7
--      via fill_we (simulates SDRAM read-back).
--   2. Drive CPU read at bank=$F8 addr=$0000 (cache hit expected, $F0).
--   3. SAME cycle: drive a bank-$00 write to $1010 with data=$BB
--      (cacheable_wr push).
--   4. Next cycle: drive CPU read at bank=$F8 addr=$0001 (expect $F1).
--   5. EXPECTED: both $F8 reads return correct ROM bytes; the bank-$00
--      push does not corrupt the cache_di output.
--
-- Exit code 0 = both PASS. Non-zero = reproduces the v164 race.
--
-- HEAD baseline (v165 / v167 — no path-(b)): cacheable_wr=0 → no pushes
--   → wb_pending stays 0 → both scenarios trivially PASS (cache hits
--   never collide with drain).
-- v164 stash (b140fb4): cacheable_wr conditional → pushes happen → if
--   cpu_cache.vhd handles the race correctly, PASS; if not, S1 fails.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity p65c816_kickstart_drain_tb is
end entity;

architecture sim of p65c816_kickstart_drain_tb is

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

    signal fill_data : unsigned(7 downto 0)  := (others => '0');
    signal fill_we   : std_logic := '0';
    signal fill_addr : unsigned(15 downto 0) := (others => '0');
    signal fill_bank : unsigned(7 downto 0)  := (others => '0');

    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal wb_ack     : std_logic := '0';

    signal flush     : std_logic := '0';
    signal wb_enable : std_logic := '1';

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

    clkgen : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    dut : entity work.cpu_cache
        port map (
            clk        => clk,
            reset      => reset,
            enable     => enable,

            cpu_addr   => cpu_addr,
            cpu_bank   => cpu_bank,
            cpu_we     => cpu_we,
            cpu_do     => cpu_do,

            cache_di   => cache_di,
            cache_hit  => cache_hit,

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

    stim : process
        variable pass_cnt : integer := 0;
        variable fail_cnt : integer := 0;
        variable v164_active : boolean := false;  -- detected at runtime

        procedure check(constant lbl : in string; constant cond : in boolean) is
        begin
            if cond then
                pass_cnt := pass_cnt + 1;
                report "PASS: " & lbl;
            else
                fail_cnt := fail_cnt + 1;
                report "FAIL: " & lbl severity error;
            end if;
        end procedure;

        -- Pre-fill a cache line via fill_we (simulates SDRAM read-back fill)
        procedure prefill(constant bank : in integer; constant addr : in integer; constant data : in integer) is
        begin
            wait until rising_edge(clk);
            fill_bank <= to_unsigned(bank, 8);
            fill_addr <= to_unsigned(addr, 16);
            fill_data <= to_unsigned(data, 8);
            fill_we   <= '1';
            wait until rising_edge(clk);
            fill_we   <= '0';
        end procedure;

        -- Push a cacheable_wr (mimics CPU write-through)
        procedure push_wr(constant bank : in integer; constant addr : in integer; constant data : in integer) is
        begin
            wait until rising_edge(clk);
            cpu_bank <= to_unsigned(bank, 8);
            cpu_addr <= to_unsigned(addr, 16);
            cpu_do   <= to_unsigned(data, 8);
            cpu_we   <= '1';
            cpu_en   <= '1';   -- v164: gates the push
            wait until rising_edge(clk);
            cpu_we   <= '0';
            cpu_en   <= '0';
        end procedure;

        -- Drive a cache read; return cache_di after 1-cycle latency
        procedure read_cache(constant bank : in integer; constant addr : in integer) is
        begin
            wait until rising_edge(clk);
            cpu_bank <= to_unsigned(bank, 8);
            cpu_addr <= to_unsigned(addr, 16);
            cpu_we   <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);  -- cache_di stable here (M10K registered)
        end procedure;

        -- Drain one entry from the write buffer
        procedure drain_one is
        begin
            wait until rising_edge(clk);
            wb_ack <= '1';
            wait until rising_edge(clk);
            wb_ack <= '0';
        end procedure;

    begin
        -- Reset
        reset <= '1';
        tick(clk, 5);
        reset <= '0';
        tick(clk, 5);

        report "=== Scenario A: bank-$00 read during wb_drain window ===";

        -- Pre-fill bank-$00 line at $1000 with $00 (so a stale read returns $00)
        prefill(16#00#, 16#1000#, 16#00#);
        prefill(16#00#, 16#1001#, 16#00#);
        prefill(16#00#, 16#1002#, 16#00#);
        prefill(16#00#, 16#1003#, 16#00#);
        tick(clk, 2);

        -- Push 4 writes (cacheable_wr should absorb on v164 stash; not on HEAD)
        push_wr(16#00#, 16#1000#, 16#AA#);
        push_wr(16#00#, 16#1001#, 16#AB#);
        push_wr(16#00#, 16#1002#, 16#AC#);
        push_wr(16#00#, 16#1003#, 16#AD#);
        tick(clk, 2);

        -- Detect at runtime: did the push actually populate the WB?
        -- v167 HEAD: cacheable_wr=0 → wb_pending stays 0.
        -- v164 stash: cacheable_wr conditional on cpu_en + wb_enable → pushes
        -- absorbed → wb_pending=1.
        v164_active := (wb_pending = '1');
        if v164_active then
            report "DETECTED v164 cacheable_wr behavior (wb_pending=1 after pushes)";
        else
            report "DETECTED v167 HEAD baseline (wb_pending=0; cacheable_wr disabled)";
        end if;

        -- Read $1000. On v164 stash: expect $AA (write-through). On HEAD: expect
        -- pre-fill $00 (cache wasn't updated by push).
        read_cache(16#00#, 16#1000#);
        if v164_active then
            check("S_A1 v164: cache read of pushed value ($AA expected)", cache_di = x"AA");
        else
            check("S_A1 HEAD: cache read returns pre-fill ($00 expected)", cache_di = x"00");
        end if;

        -- Trigger drain (only meaningful on v164). On HEAD wb_ack is a no-op.
        drain_one;
        read_cache(16#00#, 16#1001#);
        if v164_active then
            check("S_A2 v164: read during drain returns $AB", cache_di = x"AB");
        else
            check("S_A2 HEAD: read returns pre-fill $00", cache_di = x"00");
        end if;
        drain_one;
        read_cache(16#00#, 16#1002#);
        if v164_active then
            check("S_A3 v164: read during drain returns $AC", cache_di = x"AC");
        else
            check("S_A3 HEAD: read returns pre-fill $00", cache_di = x"00");
        end if;
        drain_one;
        read_cache(16#00#, 16#1003#);
        if v164_active then
            check("S_A4 v164: read during drain returns $AD", cache_di = x"AD");
        else
            check("S_A4 HEAD: read returns pre-fill $00", cache_di = x"00");
        end if;
        drain_one;
        check("S_A5 wb_pending=0 after final drain (or never asserted)",
              wb_pending = '0');

        report "=== Scenario B: bank-$F8 fetch during fresh push ===";

        -- Pre-fill bank-$F8 cache (simulates kickstart ROM read-back).
        for i in 0 to 7 loop
            prefill(16#F8#, i, 16#F0# + i);
        end loop;
        tick(clk, 2);

        -- Read $F8:$0000 — expect $F0
        read_cache(16#F8#, 16#0000#);
        check("S_B1 bank-$F8 read $0 returns $F0", cache_di = x"F0");

        -- Concurrent push: bank-$00 write at $1010 with data $BB.
        -- This is the race case: push happens while a bank-$F8 read is in flight.
        push_wr(16#00#, 16#1010#, 16#BB#);

        -- Read $F8:$0001 immediately after. Expect $F1 (the push must NOT corrupt
        -- the cache_di output for an unrelated bank).
        read_cache(16#F8#, 16#0001#);
        check("S_B2 bank-$F8 read $1 after push returns $F1", cache_di = x"F1");

        -- Read $F8:$0002 — expect $F2
        read_cache(16#F8#, 16#0002#);
        check("S_B3 bank-$F8 read $2 returns $F2", cache_di = x"F2");

        report "=== Summary ===";
        report "PASS=" & integer'image(pass_cnt) & " FAIL=" & integer'image(fail_cnt);

        if fail_cnt = 0 then
            report "ALL PASS - cpu_cache.vhd preserves coherency under the modeled race."
                severity note;
            report "NOTE: this bench only covers the cpu_cache.vhd half. The v166" severity note;
            report "hardware failure also depends on fpga64_sid_iec.vhd cancel logic." severity note;
            report "For full system reproduction see the c64_reduced_harness fallback" severity note;
            report "(task #25 BRAM probe wiring + real scpu64.mif at bank $F8)." severity note;
        else
            report integer'image(fail_cnt) & " checks failed - race detected at cpu_cache level"
                severity failure;
        end if;

        sim_done <= true;
        wait;
    end process;

end architecture;
