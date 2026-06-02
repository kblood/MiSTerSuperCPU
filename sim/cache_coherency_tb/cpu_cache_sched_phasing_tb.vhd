-- cpu_cache_sched_phasing_tb.vhd — iter-15 FAITHFUL integration bench for the
-- single registered gap-gated enable scheduler (docs/iter14_altfire_rtl_brief.md
-- "CORRECTED DESIGN"). Unlike cpu_cache_altfire_race_tb (a POLICY proof whose
-- consume == decision edge, i.e. a COMBINATIONAL enable), THIS bench models the
-- REAL RTL structure that the scheduler will have:
--
--     fire (comb at an even CPU fire-eval slot)
--       -> enableCpu <= fire        (REGISTERED: 1 extra clk32 the policy bench lacks)
--       -> the modeled P65C816 consumes at the edge AFTER the enable-high slot
--          (latches cpuDi-during-enable-slot, advances cpu_addr 1 clk32 later).
--
-- WHY THIS BENCH EXISTS: the brief's pseudocode gates the fast 2-apart fire on the
-- REGISTERED rp_same_line_d1/rp_cache_hit_d1 (matching the policy bench's sl_d1).
-- But because `enableCpu <= fire` inserts ONE register the policy bench does not
-- model, the realizable RTL must gate on the LIVE same_line/cache_hit sampled at
-- the even fire-eval slot (one slot before enable-high). This bench settles that
-- off-device: GATE_INPUT=LIVE must PASS (0 stale), GATE_INPUT=D1 must FAIL — proving
-- the live gate is the correct realization and the _d1 gate re-introduces the race.
--
-- FAITHFUL TIMING (matches fpga64_sid_iec.vhd):
--   * full 32-slot period: sysCycle 0..15 = non-CPU gap (EXT/DMA/VIC, no enable),
--     16..31 = CPU0..CPUF. enable only ever high in the CPU phase.
--   * fire-eval candidate slots = even CPU slots CPU2,4,6,8,A,C,E (=18,20,..,30).
--     A fire there raises enableCpu the FOLLOWING (odd) slot CPU3,5,..,F. Mains land
--     at CPU3/7/B/F (4-apart, the proven baseline); fasts insert at CPU5/9/D.
--   * en_gap = clk32 since the last enable-high slot. main path: en_gap>=3 (new
--     spacing>=4); fast path: en_gap>=1 (new spacing>=2) AND fast AND same-line AND hit.
--   * cpuDi override = registered rp_cache_di_d1 gated by rp_cache_hit_d1 (faithful
--     to fpga64:1987 + 4936-4939). The 816 latches cpuDi at the consume edge.
--   * per-byte fill-on-miss when PREFILL=false (faithful rp_fill_we = enable AND miss).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_cache_sched_phasing_tb is
    generic (
        -- GATE_INPUT: which same_line/cache_hit the fast 2-apart gate reads.
        --   0 = LIVE  (same_line/cache_hit at the even fire-eval slot)  -> expect PASS
        --   1 = D1    (rp_same_line_d1/rp_cache_hit_d1, the brief's pseudocode) -> expect FAIL
        GATE_INPUT : integer := 0;
        -- ALLOW_FAST: 0 = CONTROL (mains only, strict 4-apart) -> validates the model
        --             1 = scheduler with the fast 2-apart path enabled
        ALLOW_FAST : integer := 1;
        PREFILL    : boolean := true
    );
end entity;

architecture sim of cpu_cache_sched_phasing_tb is
    constant CLK_PER : time := 31.25 ns;

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal cpu_addr : unsigned(15 downto 0) := x"1000";
    signal cpu_bank : unsigned(7 downto 0)  := x"02";
    signal cpu_we   : std_logic := '0';
    signal cpu_do   : unsigned(7 downto 0) := (others => '0');
    signal cache_di : unsigned(7 downto 0);
    signal cache_hit: std_logic;
    signal same_line: std_logic;

    signal fill_data: unsigned(7 downto 0);
    signal fill_we  : std_logic;
    signal fill_addr: unsigned(15 downto 0);
    signal fill_bank: unsigned(7 downto 0);
    signal su_fill_data: unsigned(7 downto 0) := (others => '0');
    signal su_fill_we  : std_logic := '0';
    signal su_fill_addr: unsigned(15 downto 0) := (others => '0');
    signal su_fill_bank: unsigned(7 downto 0)  := (others => '0');
    signal sq_fill_data: unsigned(7 downto 0) := (others => '0');
    signal sq_fill_we  : std_logic := '0';
    signal sq_fill_addr: unsigned(15 downto 0) := (others => '0');
    signal sq_fill_bank: unsigned(7 downto 0)  := (others => '0');

    signal wb_pending : std_logic;
    signal wb_addr    : unsigned(15 downto 0);
    signal wb_data    : unsigned(7 downto 0);
    signal flush    : std_logic := '0';
    signal dbg_flush_active : std_logic;
    signal dbg_tag_match    : std_logic;

    -- registered override (mirror of fpga64:4936-4939 + the same_line registration)
    signal rp_cache_di_d1  : unsigned(7 downto 0) := (others => '0');
    signal rp_cache_hit_d1 : std_logic := '0';
    signal rp_same_line_d1 : std_logic := '0';
    signal cpuDi    : unsigned(7 downto 0);

    -- scheduler / consumer state
    signal sysCycle  : integer range 0 to 31 := 0;
    signal start_run : std_logic := '0';
    signal running   : std_logic := '0';
    signal enableCpu : std_logic := '0';
    -- latched alongside enableCpu: was THIS enable a fast 2-apart fire? Read at the
    -- consume edge to classify cold misses (en_gap always reads 0 at the consume
    -- because the enable-high slot just reset it — so the gap itself can't classify).
    signal fire_was_fast : std_logic := '0';
    signal en_gap    : integer range 0 to 63 := 63;
    signal acc_idx   : integer := 0;

    signal latch_count : integer := 0;
    signal fail_count  : integer := 0;
    signal test_done   : boolean := false;
    signal gclk_cnt    : integer := 0;
    signal first_cyc   : integer := -1;
    signal last_cyc    : integer := 0;

    type acc_t is record
        addr : unsigned(15 downto 0);
        bank : unsigned(7 downto 0);
        exp  : unsigned(7 downto 0);
    end record;
    type acc_arr_t is array(natural range <>) of acc_t;
    -- Same stream as the policy bench: lines L0 $1000-7 ($A0..A7),
    -- L1 $1008-F ($B0..B7), L2 $1010-7 ($C0..C7). Mix of same-line + cross.
    constant STREAM : acc_arr_t := (
        (x"1000", x"02", x"A0"),  --  0 L0.0
        (x"1001", x"02", x"A1"),  --  1 L0.1  same
        (x"1008", x"02", x"B0"),  --  2 L1.0  CROSS
        (x"1009", x"02", x"B1"),  --  3 L1.1  same
        (x"100A", x"02", x"B2"),  --  4 L1.2  same
        (x"1010", x"02", x"C0"),  --  5 L2.0  CROSS
        (x"1000", x"02", x"A0"),  --  6 L0.0  CROSS
        (x"1001", x"02", x"A1"),  --  7 L0.1  same
        (x"1002", x"02", x"A2"),  --  8 L0.2  same
        (x"1008", x"02", x"B0"),  --  9 L1.0  CROSS
        (x"1010", x"02", x"C0"),  -- 10 L2.0  CROSS
        (x"1011", x"02", x"C1"),  -- 11 L2.1  same
        (x"1012", x"02", x"C2"),  -- 12 L2.2  same
        (x"1000", x"02", x"A0"),  -- 13 L0.0  CROSS
        (x"1003", x"02", x"A3"),  -- 14 L0.3  same
        (x"100B", x"02", x"B3")   -- 15 L1.3  CROSS
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

    function is_fire_eval(c : integer) return boolean is
    begin
        -- even CPU slots CPU2..CPUE = 18,20,22,24,26,28,30 (CPU0=16 excluded so the
        -- first enable of a phase lands at CPU3, matching the baseline pipeline).
        return c = 18 or c = 20 or c = 22 or c = 24 or c = 26 or c = 28 or c = 30;
    end function;
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

    reg_d1: process(clk)
    begin
        if rising_edge(clk) then
            rp_cache_hit_d1 <= cache_hit;
            rp_cache_di_d1  <= cache_di;
            rp_same_line_d1 <= same_line;
        end if;
    end process;
    cpuDi <= rp_cache_di_d1 when rp_cache_hit_d1 = '1' else x"EE";

    fill_we   <= su_fill_we or sq_fill_we;
    fill_addr <= sq_fill_addr when sq_fill_we = '1' else su_fill_addr;
    fill_bank <= sq_fill_bank when sq_fill_we = '1' else su_fill_bank;
    fill_data <= sq_fill_data when sq_fill_we = '1' else su_fill_data;

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
        if PREFILL then
            for off in 0 to 7 loop
                fill_byte(to_unsigned(16#1000# + off, 16), x"02",
                          to_unsigned(16#A0# + off, 8),
                          su_fill_addr, su_fill_bank, su_fill_data, su_fill_we, clk);
            end loop;
            for off in 0 to 7 loop
                fill_byte(to_unsigned(16#1008# + off, 16), x"02",
                          to_unsigned(16#B0# + off, 8),
                          su_fill_addr, su_fill_bank, su_fill_data, su_fill_we, clk);
            end loop;
            for off in 0 to 7 loop
                fill_byte(to_unsigned(16#1010# + off, 16), x"02",
                          to_unsigned(16#C0# + off, 8),
                          su_fill_addr, su_fill_bank, su_fill_data, su_fill_we, clk);
            end loop;
        end if;
        report "=== sched phasing: PREFILL=" & boolean'image(PREFILL)
             & " GATE_INPUT=" & integer'image(GATE_INPUT)
             & " ALLOW_FAST=" & integer'image(ALLOW_FAST) & " ===";
        for i in 0 to 8 loop
            wait until rising_edge(clk);
        end loop;
        start_run <= '1';
        wait;
    end process;

    -- ── Scheduler (registered enableCpu) + modeled-816 consumer ─────────
    -- One clocked process. At each rising edge:
    --   (a) consume FIRST if enableCpu was high during the slot we are leaving
    --       (the 816 reads the pre-edge enable + pre-edge cpuDi, advances cpu_addr).
    --   (b) then evaluate `fire` for the slot we are entering's successor and set
    --       enableCpu for the NEXT slot (registered).
    -- Doing (a) before (b) in the same process is sound: (a) reads the OLD enableCpu
    -- (this edge's pre-value) and the consume's cpu_addr advance is a signal assign
    -- (visible next delta), while (b) computes the new enableCpu from the CURRENT
    -- (pre-advance) cache outputs — exactly the hardware ordering.
    sched: process(clk)
        variable c        : integer;
        variable fire     : boolean;
        variable fire_fast: boolean;
        variable gate_sl  : std_logic;
        variable gate_hit : std_logic;
        variable got      : unsigned(7 downto 0);
        variable hitv     : std_logic;
        variable expv     : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            gclk_cnt <= gclk_cnt + 1;
            c := sysCycle;
            sq_fill_we <= '0';

            if start_run = '1' and running = '0' and not test_done then
                running <= '1';
            end if;

            -- ── (a) CONSUME: the 816 steps on the pre-edge enableCpu ─────
            if enableCpu = '1' and running = '1' and not test_done then
                got  := cpuDi;
                hitv := rp_cache_hit_d1;
                expv := STREAM(acc_idx).exp;
                report "C cyc=" & integer'image(c)
                     & " gap=" & integer'image(en_gap)
                     & " idx=" & integer'image(acc_idx)
                     & " addr=" & to_hstring(std_logic_vector(STREAM(acc_idx).addr))
                     & " exp=" & to_hstring(std_logic_vector(expv))
                     & " got=" & to_hstring(std_logic_vector(got))
                     & " hit=" & std_logic'image(hitv);
                if PREFILL then
                    if got /= expv or hitv /= '1' then
                        report "  *** STALE/MISS consume idx=" & integer'image(acc_idx)
                             & " exp=" & to_hstring(std_logic_vector(expv))
                             & " got=" & to_hstring(std_logic_vector(got))
                             severity warning;
                        fail_count <= fail_count + 1;
                    end if;
                else
                    if hitv = '1' then
                        if got /= expv then
                            report "  *** HIT wrong byte idx=" & integer'image(acc_idx)
                                 severity warning;
                            fail_count <= fail_count + 1;
                        end if;
                    elsif fire_was_fast = '1' then
                        -- fast 2-apart fire that hit a cold/invalid byte = stale race.
                        -- (A main 4-apart miss is fine: SDRAM delivers + the byte fills.)
                        report "  *** FAST-MISS stale idx=" & integer'image(acc_idx)
                             severity warning;
                        fail_count <= fail_count + 1;
                    end if;
                    if hitv = '0' then
                        sq_fill_we   <= '1';
                        sq_fill_addr <= STREAM(acc_idx).addr;
                        sq_fill_bank <= STREAM(acc_idx).bank;
                        sq_fill_data <= STREAM(acc_idx).exp;
                    end if;
                end if;

                latch_count <= latch_count + 1;
                if first_cyc < 0 then first_cyc <= gclk_cnt; end if;
                last_cyc <= gclk_cnt;

                if acc_idx = STREAM'high then
                    running   <= '0';
                    test_done <= true;
                else
                    acc_idx  <= acc_idx + 1;
                    cpu_addr <= STREAM(acc_idx + 1).addr;
                    cpu_bank <= STREAM(acc_idx + 1).bank;
                end if;
            end if;

            -- ── (b) SCHEDULE: decide enableCpu for the next slot ─────────
            -- en_gap bookkeeping: reset to 0 the slot enable is high, else +1.
            fire := false;
            fire_fast := false;
            if running = '1' and not test_done and is_fire_eval(c) then
                -- gate inputs: LIVE (this fire-eval slot) vs registered _d1.
                if GATE_INPUT = 0 then
                    gate_sl  := same_line;
                    gate_hit := cache_hit;
                else
                    gate_sl  := rp_same_line_d1;
                    gate_hit := rp_cache_hit_d1;
                end if;

                if en_gap >= 3 then
                    fire := true;                       -- full-margin main (new spacing>=4)
                elsif ALLOW_FAST = 1 and en_gap >= 1
                      and gate_sl = '1' and gate_hit = '1' then
                    fire := true; fire_fast := true;    -- fast 2-apart (new spacing>=2)
                end if;
            end if;

            if fire then
                enableCpu     <= '1';
                en_gap        <= 0;
                if fire_fast then fire_was_fast <= '1'; else fire_was_fast <= '0'; end if;
            else
                enableCpu <= '0';
                if en_gap < 63 then en_gap <= en_gap + 1; end if;
            end if;

            if c = 31 then sysCycle <= 0; else sysCycle <= c + 1; end if;
        end if;
    end process;

    verdict: process
    begin
        wait until test_done;
        wait for 4 * CLK_PER;
        report "=== GATE_INPUT=" & integer'image(GATE_INPUT)
             & " ALLOW_FAST=" & integer'image(ALLOW_FAST)
             & " PREFILL=" & boolean'image(PREFILL)
             & " : latches=" & integer'image(latch_count)
             & " failures=" & integer'image(fail_count)
             & " span_clk32=" & integer'image(last_cyc - first_cyc) & " ===";
        if fail_count = 0 then
            report "=== PASS (no stale consume) ===";
        else
            report "=== FAIL: " & integer'image(fail_count)
                 & " stale/miss consume(s) ===" severity warning;
        end if;
        report "SIMULATION DONE" severity note;
        wait;
    end process;
end architecture;
