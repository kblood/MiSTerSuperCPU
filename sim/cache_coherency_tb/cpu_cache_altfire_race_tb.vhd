-- cpu_cache_altfire_race_tb.vhd — FAITHFUL reproduction of the iter-7g 2x alt-fire
-- functional consume-race, off-device (GHDL), per docs/session_handoff.md step 1+2.
--
-- BACKGROUND (iter-12, project_alt_fire_2x_timing_viable.md):
-- The 2x alt-fire (8MHz on SuperRAM cache hits) is TIMING-CLEAN at the 2-apart
-- (setup-2) cadence — the di->ALU path closes. iter-7g's HW wedge was therefore
-- FUNCTIONAL, not timing: at the 2-apart cadence the iter-7d registered override
-- (rp_cache_*_d1) delivers a STALE byte on cross-line accesses. This bench models
-- the EXACT fpga64 consume phasing so the wrong-byte consume is reproduced and a
-- correct gating policy can be proven — all without the MiSTer.
--
-- FAITHFUL PHASING (RTL-traced, fpga64_sid_iec.vhd):
--   * cpu_cache: cache_hit/same_line are COMBINATIONAL on the live cpuAddr;
--     cache_di = byteselect(line_word), and line_word is REGISTERED 1 clk32 after
--     the address (cpu_cache.vhd:283-296). So cache_di reflects addr(E-1).
--   * fpga64:4936-4939 registers the override ONE more clk32: rp_cache_di_d1.
--     => cpuDi(E) = rp_cache_di_d1(E) reflects addr(E-2).
--   * A latch (enableCpu) consuming the access on cpuAddr(E) gets cpuDi(E),
--     i.e. data for addr(E-2). SAFE iff addr(E-2) is the SAME LINE as addr(E).
--   * cpuAddr advances exactly 1 clk32 AFTER each latch (the 816 steps).
--
-- LATCH CADENCE (1 clk32 per sysCycle, 0..15):
--   main latches (always)         : sysCycle 2,6,10,14   (4-apart base = 4MHz)
--   alt  latches (gated, +1 step) : sysCycle 4,8,12,0     (2 after a main = 8MHz)
--   "cycles_since_latch" (csl): edges since the last latch. csl>=4 = full margin
--   (cross-line safe); csl=2 = 2-apart (cross-line UNSAFE, same-line OK).
--
-- GATE_MODE (generic):
--   3 = CONTROL: no alt ever (pure 4-apart). Must be 0 failures => validates the
--       bench phasing model itself.
--   0 = iter-7g BUG: alt gated on same_line sampled at the MAIN-latch cycle
--       (before cpuAddr advances). At a main-latch cycle the addr has been stable
--       for the whole slot => same_line reads '1' ALWAYS => the gate is a NO-OP =>
--       alt fires unconditionally => every cross-line consume is STALE. WEDGE.
--   1 = TIMING-FIXED: alt gated on same_line sampled 1 clk32 LATER (after cpuAddr
--       advanced to the access the alt slot will consume) => alt correctly fires
--       only on genuine same-line. BUT a fired alt makes the FOLLOWING main slot a
--       2-apart latch (csl=2); if that access is cross-line it is STILL STALE.
--       Residual failures => timing-of-decision fix alone is INSUFFICIENT.
--   2 = UNIFIED FIX: treat EVERY even cycle as a latch candidate; latch iff
--       (csl>=4 full margin) OR (current access same-line as the previously
--       CONSUMED access). Otherwise STALL (skip, let margin rebuild to 4). This is
--       the correct invariant for the whole cadence (covers alt slots AND post-alt
--       main slots). Must be 0 failures AND latch_count > control (proves speedup).
--       BUT mode 2 decides on an ORACLE (STREAM(acc_idx) vs prev_cons_addr) —
--       a peek the real RTL cannot do at the latch cycle.
--   5 = REALIZABLE FIX (mode 2's policy via a 1-clk-enable, E-1 registered
--       decision — the realizability proof per session_handoff.md step 2).
--       The fast-path same-line decision is NOT an oracle: it is the cache's LIVE
--       `same_line` output, sampled ONE clk32 before the latch (sl_d1) and
--       registered, exactly as a 1-clk enable (cpu_cyc_s(0)) would deliver it.
--       Phasing proof: a 2-apart fast latch at cycle E has its previous latch at
--       E-2; at edge E-1 cpu_addr has already advanced to access(E) (set at the
--       E-2 latch) while cpu_cache.prev_line still holds access(E-1)=prev-consumed,
--       so same_line(E-1) == "access(E) same-line as prev-consumed" == mode 2's
--       condition. Latch iff (csl>=4 full margin, the normal 2-clk-enable path)
--       OR (sl_d1='1', the 1-clk-enable fast path); else STALL. A spurious sl_d1
--       during a stall is harmless: that candidate has csl>=4 and the full-margin
--       path dominates. Must MATCH mode 2 EXACTLY (0 failures, same latch_count) —
--       that equality is the proof the realizable decision phase implements the
--       policy that the oracle proved correct. iter-7g failed precisely because it
--       kept the 2-clk enable (decision at E-2, before access(E)'s addr existed on
--       the bus) and only changed the gate; mode 5 moves the decision to E-1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_altfire_race_tb is
    generic ( GATE_MODE : integer := 0 );
end entity;

architecture sim of cpu_cache_altfire_race_tb is
    constant CLK_PER : time := 31.25 ns; -- 32MHz

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal cpu_addr : unsigned(15 downto 0) := x"1000"; -- primed on STREAM(0)
    signal cpu_bank : unsigned(7 downto 0)  := x"02";
    signal cpu_we   : std_logic := '0';
    signal cpu_do   : unsigned(7 downto 0) := (others => '0');
    signal cache_di : unsigned(7 downto 0);
    signal cache_hit: std_logic;
    signal same_line: std_logic;

    signal fill_data: unsigned(7 downto 0) := (others => '0');
    signal fill_we  : std_logic := '0';
    signal fill_addr: unsigned(15 downto 0) := (others => '0');
    signal fill_bank: unsigned(7 downto 0)  := (others => '0');

    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal flush    : std_logic := '0';
    signal dbg_flush_active : std_logic;
    signal dbg_tag_match    : std_logic;

    -- iter-7d registered override (mirror of fpga64_sid_iec.vhd:4936-4939)
    signal rp_cache_di_d1  : unsigned(7 downto 0) := (others => '0');
    signal rp_cache_hit_d1 : std_logic := '0';
    -- mode 5: the cache's live same_line, registered 1 clk32 (E-1 decision via a
    -- 1-clk enable). This is the realizable replacement for mode 2's oracle.
    signal sl_d1           : std_logic := '0';
    -- cpuDi override mux (mirror of fpga64_sid_iec.vhd:1987)
    signal cpuDi    : unsigned(7 downto 0);

    -- sequencer / consumer state
    signal sysCycle : integer range 0 to 15 := 0;
    signal start_run: std_logic := '0';  -- driven by setup only
    signal running  : std_logic := '0';  -- driven by seq only
    signal acc_idx  : integer := 0;
    signal alt_armed: std_logic := '0';
    signal cycles_since_latch : integer := 99;
    signal prev_cons_addr : unsigned(15 downto 0) := x"1000";
    signal prev_cons_bank : unsigned(7 downto 0)  := x"02";

    signal latch_count : integer := 0;
    signal fail_count  : integer := 0;
    signal test_done   : boolean := false;
    signal gclk_cnt    : integer := 0;   -- free-running clk32 counter
    signal first_cyc   : integer := -1;   -- gclk at first latch
    signal last_cyc    : integer := 0;    -- gclk at last latch

    -- ── Access stream (all bank $02 = SuperRAM, cacheable) ──────────────
    -- Memory model (prefilled): line L0 $1000-$1007 = $A0..$A7,
    --   L1 $1008-$100F = $B0..$B7, L2 $1010-$1017 = $C0..$C7.
    type acc_t is record
        addr : unsigned(15 downto 0);
        bank : unsigned(7 downto 0);
        exp  : unsigned(7 downto 0);
    end record;
    type acc_arr_t is array(natural range <>) of acc_t;
    constant STREAM : acc_arr_t := (
        (x"1000", x"02", x"A0"),  --  0 L0.0
        (x"1001", x"02", x"A1"),  --  1 L0.1  same as prev
        (x"1008", x"02", x"B0"),  --  2 L1.0  CROSS (after same-line pair: mode1 killer)
        (x"1009", x"02", x"B1"),  --  3 L1.1  same
        (x"100A", x"02", x"B2"),  --  4 L1.2  same
        (x"1010", x"02", x"C0"),  --  5 L2.0  CROSS
        (x"1000", x"02", x"A0"),  --  6 L0.0  CROSS
        (x"1001", x"02", x"A1"),  --  7 L0.1  same
        (x"1002", x"02", x"A2"),  --  8 L0.2  same
        (x"1008", x"02", x"B0"),  --  9 L1.0  CROSS (after run of 3: mode1 killer)
        (x"1010", x"02", x"C0"),  -- 10 L2.0  CROSS
        (x"1011", x"02", x"C1"),  -- 11 L2.1  same
        (x"1012", x"02", x"C2"),  -- 12 L2.2  same
        (x"1000", x"02", x"A0"),  -- 13 L0.0  CROSS
        (x"1003", x"02", x"A3"),  -- 14 L0.3  same
        (x"100B", x"02", x"B3")   -- 15 L1.3  CROSS (after same-line pair: mode1 killer)
    );

    procedure fill_byte(addr : in unsigned(15 downto 0);
                        bank : in unsigned(7 downto 0);
                        data : in unsigned(7 downto 0);
                        signal fa : out unsigned(15 downto 0);
                        signal fb : out unsigned(7 downto 0);
                        signal fd : out unsigned(7 downto 0);
                        signal fw : out std_logic;
                        signal c  : in  std_logic) is
    begin
        fa <= addr; fb <= bank; fd <= data; fw <= '1';
        wait until rising_edge(c);
        fw <= '0';
        wait until rising_edge(c);
    end procedure;
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
        clk => clk, reset => reset, enable => '1',
        cpu_addr => cpu_addr, cpu_bank => cpu_bank,
        cpu_we => cpu_we, cpu_do => cpu_do,
        cache_di => cache_di, cache_hit => cache_hit,
        fill_data => fill_data, fill_we => fill_we,
        fill_addr => fill_addr, fill_bank => fill_bank,
        snoop_we => '0', snoop_addr => (others=>'0'), snoop_bank => (others=>'0'),
        wb_pending => wb_pending, wb_addr => wb_addr, wb_data => wb_data,
        wb_ack => '0', flush => flush, cpu_en => '0',
        wb_enable => '0', same_line => same_line,
        dbg_flush_active => dbg_flush_active, dbg_tag_match => dbg_tag_match
    );

    -- iter-7d registered override + cpuDi mux (faithful to fpga64)
    reg_d1: process(clk)
    begin
        if rising_edge(clk) then
            rp_cache_hit_d1 <= cache_hit;
            rp_cache_di_d1  <= cache_di;
            sl_d1           <= same_line;  -- E-1 sample for the 1-clk-enable fast path
        end if;
    end process;
    cpuDi <= rp_cache_di_d1 when rp_cache_hit_d1 = '1' else x"EE"; -- $EE = miss marker

    -- ── Setup: reset, flush, prefill the three lines ────────────────────
    setup: process
    begin
        reset <= '1';
        wait for 5 * CLK_PER;
        reset <= '0';
        flush <= '1';
        wait for 2 * CLK_PER;
        flush <= '0';
        for i in 0 to 600 loop
            wait until rising_edge(clk);
        end loop;
        -- Prefill L0/L1/L2 (8 bytes each).
        for off in 0 to 7 loop
            fill_byte(to_unsigned(16#1000# + off, 16), x"02",
                      to_unsigned(16#A0# + off, 8),
                      fill_addr, fill_bank, fill_data, fill_we, clk);
        end loop;
        for off in 0 to 7 loop
            fill_byte(to_unsigned(16#1008# + off, 16), x"02",
                      to_unsigned(16#B0# + off, 8),
                      fill_addr, fill_bank, fill_data, fill_we, clk);
        end loop;
        for off in 0 to 7 loop
            fill_byte(to_unsigned(16#1010# + off, 16), x"02",
                      to_unsigned(16#C0# + off, 8),
                      fill_addr, fill_bank, fill_data, fill_we, clk);
        end loop;
        report "=== Prefill complete (GATE_MODE=" & integer'image(GATE_MODE) & ") ===";
        -- let the pipeline settle on STREAM(0) before starting the cadence
        for i in 0 to 8 loop
            wait until rising_edge(clk);
        end loop;
        start_run <= '1';
        wait;
    end process;

    -- ── Sequencer + consumer (faithful cadence + consume phasing) ───────
    seq: process(clk)
        variable c        : integer;
        variable do_latch : boolean;
        variable is_main  : boolean;
        variable is_alt   : boolean;
        variable safe     : boolean;
        variable got      : unsigned(7 downto 0);
        variable hitv     : std_logic;
        variable expv     : unsigned(7 downto 0);
        variable kind     : string(1 to 4);
    begin
        if rising_edge(clk) then
            gclk_cnt <= gclk_cnt + 1;
            c := sysCycle;
            do_latch := false;
            kind := "----";

            if start_run = '1' and running = '0' and not test_done then
                running <= '1';
            end if;

            is_main := (c = 2) or (c = 6) or (c = 10) or (c = 14);
            is_alt  := (c = 4) or (c = 8) or (c = 12) or (c = 0);

            -- alt-fire decision sampling (modes 0/1 only)
            if GATE_MODE = 0 then
                -- BUG: sample at the main-latch cycle (addr not yet advanced)
                if c = 2 or c = 6 or c = 10 or c = 14 then
                    alt_armed <= same_line;
                end if;
            elsif GATE_MODE = 1 then
                -- FIXED TIMING: sample 1 clk32 later (addr now = alt's access)
                if c = 3 or c = 7 or c = 11 or c = 15 then
                    alt_armed <= same_line;
                end if;
            end if;

            if running = '1' and not test_done then
                if GATE_MODE = 3 then
                    do_latch := is_main;
                    if is_main then kind := "main"; end if;
                elsif GATE_MODE = 0 or GATE_MODE = 1 then
                    if is_main then
                        do_latch := true; kind := "main";
                    elsif is_alt then
                        do_latch := (alt_armed = '1');
                        if do_latch then kind := "alt "; end if;
                    end if;
                elsif GATE_MODE = 2 then -- unified gap + same-line-vs-prev-consumed (ORACLE)
                    if (c mod 2) = 0 then
                        if cycles_since_latch >= 4 then
                            safe := true;  kind := "full";
                        elsif STREAM(acc_idx).bank = prev_cons_bank
                          and STREAM(acc_idx).addr(15 downto 3) = prev_cons_addr(15 downto 3) then
                            safe := true;  kind := "sl2 ";  -- same-line 2-apart
                        else
                            safe := false; kind := "STAL"; -- stall to rebuild margin
                        end if;
                        do_latch := safe;
                    end if;
                else -- GATE_MODE = 5 : REALIZABLE — same policy, but the fast-path
                     -- decision is the cache's LIVE same_line sampled at E-1 (sl_d1),
                     -- NOT the oracle. Must match mode 2 exactly.
                    if (c mod 2) = 0 then
                        if cycles_since_latch >= 4 then
                            safe := true;  kind := "full"; -- normal 2-clk-enable path
                        elsif sl_d1 = '1' then
                            safe := true;  kind := "sl2 "; -- 1-clk-enable fast path
                        else
                            safe := false; kind := "STAL"; -- stall to rebuild margin
                        end if;
                        do_latch := safe;
                    end if;
                end if;
            end if;

            if do_latch then
                got  := cpuDi;
                hitv := rp_cache_hit_d1;
                expv := STREAM(acc_idx).exp;
                report "L cyc=" & integer'image(c)
                     & " csl=" & integer'image(cycles_since_latch)
                     & " kind=" & kind
                     & " idx=" & integer'image(acc_idx)
                     & " addr=" & to_hstring(std_logic_vector(STREAM(acc_idx).addr))
                     & " exp=" & to_hstring(std_logic_vector(expv))
                     & " got=" & to_hstring(std_logic_vector(got))
                     & " hit=" & std_logic'image(hitv);
                if got /= expv or hitv /= '1' then
                    report "  *** STALE/MISS consume: idx=" & integer'image(acc_idx)
                         & " exp=" & to_hstring(std_logic_vector(expv))
                         & " got=" & to_hstring(std_logic_vector(got))
                         severity warning;
                    fail_count <= fail_count + 1;
                end if;

                latch_count <= latch_count + 1;
                if first_cyc < 0 then first_cyc <= gclk_cnt; end if;
                last_cyc <= gclk_cnt;
                prev_cons_addr <= STREAM(acc_idx).addr;
                prev_cons_bank <= STREAM(acc_idx).bank;
                cycles_since_latch <= 1;

                if acc_idx = STREAM'high then
                    running <= '0';
                    test_done <= true;
                else
                    acc_idx  <= acc_idx + 1;
                    cpu_addr <= STREAM(acc_idx + 1).addr;
                    cpu_bank <= STREAM(acc_idx + 1).bank;
                end if;
            else
                cycles_since_latch <= cycles_since_latch + 1;
            end if;

            if c = 15 then sysCycle <= 0; else sysCycle <= c + 1; end if;
        end if;
    end process;

    -- ── Verdict ─────────────────────────────────────────────────────────
    verdict: process
    begin
        wait until test_done;
        wait for 2 * CLK_PER;
        report "=== GATE_MODE=" & integer'image(GATE_MODE)
             & " : latches=" & integer'image(latch_count)
             & " failures=" & integer'image(fail_count)
             & " span_clk32=" & integer'image(last_cyc - first_cyc)
             & " clk32_per_access=" & integer'image((last_cyc - first_cyc) * 100 / (latch_count - 1)) & "/100"
             & " (4-apart=400/100=4.0MHz-equiv, 2-apart=200/100=8MHz) ===";
        if fail_count = 0 then
            report "=== PASS (no stale consume) ===";
        else
            report "=== FAIL: " & integer'image(fail_count)
                 & " stale/miss consume(s) reproduced ===" severity warning;
        end if;
        report "SIMULATION DONE" severity note;
        wait;
    end process;
end architecture;
