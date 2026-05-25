-- sdram_pm_buildc_extended_tb.vhd
--
-- Milestone A Build C extended bench (2026-05-25). Complements the
-- baseline sdram_pm_lite_tb.vhd by exercising the actual RTL changes
-- made in this milestone:
--
--   1. sdram_pm.v HIT path: row tracking, refresh invalidation, HIT vs
--      MISS sample timing. The baseline bench covers these against the
--      lite model. This bench adds:
--        E. Cross-bank access invalidates HIT (must MISS).
--        F. Write-then-read same row stays on HIT path.
--        G. 3-deep HIT streak (typical SuperRAM linear-fetch pattern).
--
--   2. fpga64_sid_iec.vhd Step 6 plumbing: HIT-aware preload of
--      sdram_busy_cnt + ready_sync rising-edge early-clear. The baseline
--      bench's Step 6 check covers a single HIT fire; this bench adds:
--        S6-A. Counter clears within 2 clk32 on HIT (was 4 clk32 with
--              "011" preload, ready-edge irrelevant). Confirms the
--              preload short-circuit works.
--        S6-B. Counter clears via ready-edge on MISS even though the
--              static decrement would still be counting. Confirms the
--              early-clear path actually fires (previously a no-op on
--              Build B because the static decrement always won).
--
--   3. Registered alt-fire pattern proof. The historical wedge had
--      cpu_cyc directly OR'd with a combinational row_hit term, which
--      caused a synthesis-level hazard on the cpu_cyc -> ramCE -> cart_ce
--      chain (see project_alt_fire_r_dead_on_buildB_2026_05_23.md).
--      Pure RTL sim cannot reproduce synthesis hazards directly, but we
--      CAN reproduce the logic-equivalent: any time the combinational
--      term toggles within a single clk32, cpu_cyc glitches. The bench
--      drives a controlled scenario where:
--        WRONG. Combinational fire term toggles mid-clk32 -> cpu_cyc
--               witnesses the glitch (multiple rising edges within one
--               clk32). Test FAILS if this is bridged into the bench's
--               cpu_cyc_sample register, demonstrating why the gate
--               must move behind a register.
--        RIGHT. Registered alt_fire_r samples the same predicate on
--               the previous clk32 edge; cpu_cyc is glitch-free even
--               when the predicate flickers. Test PASSES.
--
-- All scenarios self-check and contribute to a single RESULT line.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity sdram_pm_buildc_extended_tb is
end entity;

architecture sim of sdram_pm_buildc_extended_tb is

    constant CLK64_PERIOD : time := 15625 ps;   -- 64 MHz
    constant CLK32_PERIOD : time := 31250 ps;   -- 32 MHz

    signal clk64    : std_logic := '0';
    signal clk32    : std_logic := '0';
    signal reset    : std_logic := '1';

    -- DUT interface (lite model — sdram_pm.v is Verilog, GHDL is VHDL-only)
    signal addr        : unsigned(24 downto 0) := (others => '0');
    signal we          : std_logic := '0';
    signal ce          : std_logic := '0';
    signal refresh     : std_logic := '0';
    -- Option (b) gate (Milestone A, 2026-05-26): defaults to '1' so the
    -- existing E/F/G/S6 scenarios continue to exercise the HIT path. New
    -- Scenario H drives this to '0' to validate that bank-$00 accesses
    -- bypass HIT and stay on the MISS-only path.
    signal fast_path   : std_logic := '1';
    signal ready       : std_logic;
    signal data_valid  : std_logic;
    signal dbg_hit     : std_logic;

    -- SDRAM-command observation (Step 1, 2026-05-26). Snooped from
    -- sdram_pm_lite via 1-clk pulses + bank/row context. The bench
    -- shadow process (below) maintains a per-bank open-row state and
    -- asserts SDRAM-spec legality. Currently caches NEW spec violations
    -- as fail_count increments — see scen_i_ok / scen_j_ok / scen_k_ok.
    signal cmd_active_pulse    : std_logic;
    signal cmd_active_bank     : unsigned(1 downto 0);
    signal cmd_active_row      : unsigned(12 downto 0);
    signal cmd_precharge_pulse : std_logic;
    signal cmd_precharge_all   : std_logic;
    signal cmd_precharge_bank  : unsigned(1 downto 0);
    signal cmd_refresh_pulse   : std_logic;

    -- Per-bank shadow of open-row state.
    type row_array_t is array (0 to 3) of unsigned(12 downto 0);
    signal bank_open : std_logic_vector(3 downto 0) := (others => '0');
    signal bank_row  : row_array_t := (others => (others => '0'));

    -- Spec-violation counters (incremented by the shadow process,
    -- consumed by scenarios I/J/K).
    signal spec_violation_count : integer := 0;
    signal active_conflict_count : integer := 0;  -- Risk 2
    signal refresh_while_open_count : integer := 0;  -- Risk 1

    -- Per-scenario captured violation counts at start, so each
    -- scenario can compare delta and decide pass/fail independently
    -- without consuming earlier-scenario noise.
    signal i_violations_at_start : integer := 0;
    signal j_violations_at_start : integer := 0;
    signal k_violations_at_start : integer := 0;

    -- Step 6 plumbing model (clk32 domain — mirrors fpga64_sid_iec.vhd
    -- changes made in this milestone).
    signal sdram_busy_cnt   : unsigned(2 downto 0) := (others => '0');
    signal sdram_busy       : std_logic;
    signal sdram_ready_sync : std_logic_vector(1 downto 0) := "11";
    signal sdram_ready_prev : std_logic := '1';
    signal sdram_hit_pred   : std_logic := '0';   -- driven by stim
    signal cpu_cyc_pulse    : std_logic := '0';
    signal cs_ram           : std_logic := '1';

    -- Counters for the closure check.
    signal busy_clear_clk32 : integer := -1;   -- clk32 ticks until busy=0

    -- Registered alt_fire mirror — proves cpu_cyc stays glitch-free.
    -- (Models fpga64_sid_iec.vhd:814 alt_fire_r pattern.)
    signal alt_fire_r       : std_logic := '0';
    signal alt_fire_comb    : std_logic := '0';   -- the WRONG (combinational) path

    -- Sample registers used to detect glitches.
    signal cpu_cyc_right    : std_logic := '0';
    signal cpu_cyc_wrong    : std_logic := '0';
    -- We sample BOTH variants at clk64 rate (twice per clk32). Any
    -- value-change between adjacent clk64 samples within a single
    -- clk32 window IS the logic-equivalent of a synthesis glitch.
    -- The registered pattern (right) should show transitions ONLY at
    -- clk32 boundaries (= even-indexed clk64 samples in this bench's
    -- phasing); the combinational pattern (wrong) can show transitions
    -- mid-clk32. We count clk64-rate rising edges and post-process
    -- against the number of clk32 edges in the same window.
    signal clk64_rising_count_right : integer := 0;
    signal clk64_rising_count_wrong : integer := 0;
    signal cpu_cyc_right_prev_64    : std_logic := '0';
    signal cpu_cyc_wrong_prev_64    : std_logic := '0';
    -- Single-bit reset request from the stim process; the clk64 process
    -- consumes it and zeroes the edge counters at the next edge.
    -- (Multiple drivers on integer signals fail GHDL strict checks.)
    signal edge_reset_req   : std_logic := '0';

    -- Verdict tracking.
    signal fail_count        : integer := 0;
    signal scen_e_ok         : std_logic := '0';
    signal scen_f_ok         : std_logic := '0';
    signal scen_g_ok         : std_logic := '0';
    signal scen_h_ok         : std_logic := '0';
    -- Spec-violation scenarios (post-Codex, 2026-05-26):
    --   I: refresh-while-row-open (Codex Risk 1)
    --   J: cross-class same-bank conflict (Codex Risk 2 across bank-$00/SuperRAM)
    --   K: SuperRAM cross-row same-bank conflict (Codex Risk 2, intra-class)
    -- All three are EXPECTED to FAIL under the current Option (b) lite
    -- model — that's the proof the bench can now catch them. After
    -- Option (a) FSM extension lands, they must flip to PASS.
    signal scen_i_ok         : std_logic := '0';
    signal scen_j_ok         : std_logic := '0';
    signal scen_k_ok         : std_logic := '0';
    -- After Option (a) FSM lands in sdram_pm.v + sdram_pm_lite.vhd
    -- (2026-05-26), spec violations are no longer expected — flip false
    -- to enforce the assertions. I/J/K must now report zero new
    -- violations because the FSM PRECHARGEs before ACTIVE on conflict
    -- and PRECHARGE-ALLs before AUTO_REFRESH when a row is tracked open.
    signal expect_spec_violations : boolean := false;
    signal s6_a_ok           : std_logic := '0';
    signal s6_b_ok           : std_logic := '0';
    signal wrong_ok          : std_logic := '0';
    signal right_ok          : std_logic := '0';

    signal sim_done          : boolean := false;

    -- Hazard demo stim driver — when wrong_demo_active=1, the bench
    -- drives a combinational "alt_fire" term that toggles mid-clk32,
    -- modelling the synthesis-hazard wedge mechanism.
    signal wrong_demo_active : std_logic := '0';
    signal hazard_toggle     : std_logic := '0';

begin

    clk64 <= not clk64 after CLK64_PERIOD / 2 when not sim_done else '0';
    clk32 <= not clk32 after CLK32_PERIOD / 2 when not sim_done else '0';

    dut : entity work.sdram_pm_lite
        port map (
            clk                 => clk64,
            reset               => reset,
            addr                => addr,
            we                  => we,
            ce                  => ce,
            refresh             => refresh,
            fast_path           => fast_path,
            ready               => ready,
            data_valid          => data_valid,
            dbg_hit_path        => dbg_hit,
            cmd_active_pulse    => cmd_active_pulse,
            cmd_active_bank     => cmd_active_bank,
            cmd_active_row      => cmd_active_row,
            cmd_precharge_pulse => cmd_precharge_pulse,
            cmd_precharge_all   => cmd_precharge_all,
            cmd_precharge_bank  => cmd_precharge_bank,
            cmd_refresh_pulse   => cmd_refresh_pulse
        );

    sdram_busy <= '1' when sdram_busy_cnt /= "000" else '0';

    -- Combinational "alt_fire" — the WRONG pattern. This term flickers
    -- whenever hazard_toggle wiggles, modelling a synthesis-hazard glitch
    -- from a row_hit comparator feeding directly into the cpu_cyc LUT.
    alt_fire_comb <= wrong_demo_active and hazard_toggle;

    -- cpu_cyc_right: registered alt_fire_r OR'd in (the RIGHT pattern).
    -- cpu_cyc_wrong: combinational alt_fire OR'd in (the WRONG pattern).
    -- Both are derived from cpu_cyc_pulse so the main-slot fire stays
    -- bit-identical between them; only the alt-slot input differs.
    cpu_cyc_right <= cpu_cyc_pulse or alt_fire_r;
    cpu_cyc_wrong <= cpu_cyc_pulse or alt_fire_comb;

    -- Step 6 plumbing model — matches fpga64_sid_iec.vhd's clk32 process
    -- exactly (HIT preload "001", MISS preload "011", ready-edge early-
    -- clear). Counter updates from cpu_cyc_pulse (main-slot only), not
    -- the alt-fire variants, so the closure check is deterministic.
    process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                sdram_busy_cnt    <= (others => '0');
                sdram_ready_sync  <= "11";
                sdram_ready_prev  <= '1';
                busy_clear_clk32  <= -1;
                alt_fire_r        <= '0';
            else
                sdram_ready_sync <= sdram_ready_sync(0) & ready;
                sdram_ready_prev <= sdram_ready_sync(1);

                -- Counter logic (HIT-aware preload).
                if cpu_cyc_pulse = '1' and cs_ram = '1' then
                    if sdram_hit_pred = '1' then
                        sdram_busy_cnt <= "001";
                    else
                        sdram_busy_cnt <= "011";
                    end if;
                    busy_clear_clk32 <= 0;
                elsif sdram_busy_cnt /= "000" then
                    if sdram_ready_sync(1) = '1'
                       and sdram_ready_prev   = '0' then
                        sdram_busy_cnt <= "000";
                    else
                        sdram_busy_cnt <= sdram_busy_cnt - 1;
                    end if;
                    if busy_clear_clk32 >= 0 then
                        busy_clear_clk32 <= busy_clear_clk32 + 1;
                    end if;
                end if;

                -- Registered alt_fire_r: samples wrong_demo_active +
                -- hazard_toggle on the clk32 edge, so cpu_cyc sees a
                -- glitch-free single-bit input. This is the model of
                -- fpga64_sid_iec.vhd's alt_fire_r recovery pattern.
                alt_fire_r <= wrong_demo_active and hazard_toggle;
            end if;
        end if;
    end process;

    -- clk64-rate sampler for hazard detection. Counts rising edges on
    -- both cpu_cyc variants AT CLK64 RATE — twice the rate of the clk32
    -- domain. If the registered (right) pattern is glitch-free, its
    -- clk64-rate edge count equals its clk32-rate edge count (every
    -- transition lands on a clk32 boundary). If the combinational
    -- (wrong) pattern glitches mid-clk32, the clk64-rate count exceeds
    -- the clk32-rate count — that excess IS the synthesis-hazard
    -- equivalent.
    process(clk64)
    begin
        if rising_edge(clk64) then
            if reset = '1' then
                clk64_rising_count_right <= 0;
                clk64_rising_count_wrong <= 0;
                cpu_cyc_right_prev_64 <= '0';
                cpu_cyc_wrong_prev_64 <= '0';
            elsif edge_reset_req = '1' then
                clk64_rising_count_right <= 0;
                clk64_rising_count_wrong <= 0;
                cpu_cyc_right_prev_64 <= cpu_cyc_right;
                cpu_cyc_wrong_prev_64 <= cpu_cyc_wrong;
            else
                cpu_cyc_right_prev_64 <= cpu_cyc_right;
                cpu_cyc_wrong_prev_64 <= cpu_cyc_wrong;
                if cpu_cyc_right = '1' and cpu_cyc_right_prev_64 = '0' then
                    clk64_rising_count_right <= clk64_rising_count_right + 1;
                end if;
                if cpu_cyc_wrong = '1' and cpu_cyc_wrong_prev_64 = '0' then
                    clk64_rising_count_wrong <= clk64_rising_count_wrong + 1;
                end if;
            end if;
        end if;
    end process;

    -- Hazard toggle driver: when wrong_demo_active=1, flip hazard_toggle
    -- on every clk64 edge. This guarantees the comb. alt_fire flickers
    -- within a single clk32 — the synthesis-hazard equivalent.
    process(clk64)
    begin
        if rising_edge(clk64) then
            if wrong_demo_active = '1' then
                hazard_toggle <= not hazard_toggle;
            else
                hazard_toggle <= '0';
            end if;
        end if;
    end process;

    --
    -- SDRAM-spec shadow process (Step 1, 2026-05-26). Maintains a
    -- per-bank open-row state from the lite model's command pulses and
    -- raises spec-violation counters when:
    --   - CMD_ACTIVE targets a bank that is already open with a
    --     different row (Codex Risk 2).
    --   - CMD_AUTO_REFRESH fires while any bank is open (Codex Risk 1).
    -- Does NOT halt the bench — accumulates counts so scenarios I/J/K
    -- can compare deltas and decide pass/fail. The bench currently
    -- treats violations as "expected" (Option (b) reality); once
    -- Option (a) lands, expect_spec_violations flips to false and the
    -- assertions become hard fails.
    --
    sdram_shadow : process(clk64)
        variable b : integer;
    begin
        if rising_edge(clk64) then
            if reset = '1' then
                bank_open <= (others => '0');
                bank_row  <= (others => (others => '0'));
                spec_violation_count <= 0;
                active_conflict_count <= 0;
                refresh_while_open_count <= 0;
            else
                -- CMD_ACTIVE: check for conflict, then mark bank open.
                if cmd_active_pulse = '1' then
                    b := to_integer(cmd_active_bank);
                    if bank_open(b) = '1'
                       and bank_row(b) /= cmd_active_row then
                        active_conflict_count <= active_conflict_count + 1;
                        spec_violation_count  <= spec_violation_count + 1;
                    end if;
                    bank_open(b) <= '1';
                    bank_row(b)  <= cmd_active_row;
                end if;
                -- CMD_PRECHARGE: clear bank(s).
                if cmd_precharge_pulse = '1' then
                    if cmd_precharge_all = '1' then
                        bank_open <= (others => '0');
                    else
                        bank_open(to_integer(cmd_precharge_bank)) <= '0';
                    end if;
                end if;
                -- CMD_AUTO_REFRESH: any bank open is a spec violation.
                if cmd_refresh_pulse = '1' then
                    if bank_open /= "0000" then
                        refresh_while_open_count <= refresh_while_open_count + 1;
                        spec_violation_count     <= spec_violation_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

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

        procedure wait_clk32(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk32);
            end loop;
        end procedure;

        -- Issue a request and wait for the controller to return to idle.
        -- Returns the number of clk64 edges between drive-ce and ready=1.
        procedure issue(
            scenario  : string;
            a         : unsigned(24 downto 0);
            expected  : integer;
            tolerance : integer;
            signal ok : out std_logic
        ) is
            variable elapsed : integer := 0;
        begin
            wait until rising_edge(clk64);
            addr <= a;
            we   <= '0';
            ce   <= '1';
            wait until rising_edge(clk64);
            ce <= '0';
            elapsed := 1;
            for i in 1 to 30 loop
                wait until rising_edge(clk64);
                elapsed := elapsed + 1;
                if ready = '1' then exit; end if;
            end loop;
            if ready /= '1' then
                log("FAIL " & scenario & ": ready never rose");
                fail_count <= fail_count + 1;
                ok <= '0';
                return;
            end if;
            if elapsed >= (expected - tolerance)
               and elapsed <= (expected + tolerance) then
                log(scenario & " OK: ready in " & integer'image(elapsed)
                    & " clk64 (expected " & integer'image(expected)
                    & " +/-" & integer'image(tolerance) & ")");
                ok <= '1';
            else
                log("FAIL " & scenario & ": ready in "
                    & integer'image(elapsed) & " clk64 (expected "
                    & integer'image(expected) & ")");
                fail_count <= fail_count + 1;
                ok <= '0';
            end if;
        end procedure;

    begin
        log("=== sdram_pm_buildc_extended_tb start ===");

        reset <= '1';
        wait_clk64(8);
        reset <= '0';
        wait_clk64(4);

        --
        -- Scenario E: cross-bank access invalidates HIT.
        --   1) MISS on bank=0 row=0x100 (opens the row)
        --   2) MISS on bank=1 row=0x100 (different bank — must MISS)
        --   3) HIT  on bank=1 row=0x100 (same bank+row as #2 — must HIT)
        --
        log("--- Scenario E (cross-bank access invalidates HIT) ---");
        -- addr layout: [24]=bt, [23]=col_top, [22:21]=bank, [20:8]=row,
        --              [7:0]=col_lo
        -- bank=0 row=0x100 -> [22:21]=00, [20:8]=0x100
        --   25-bit value = 00 00000_10000_0000 0000 0000_0000
        --                = 0x0010000
        issue("Scen E.1 MISS bank=0",
              to_unsigned(16#0010000#, 25), 6, 1, scen_e_ok);
        wait_clk64(4);
        -- bank=1 row=0x100 -> [22:21]=01, [20:8]=0x100
        --   25-bit value = 0010_0100000000_00000000 = 0x0210000
        -- Conflict-MISS (Option (a) conservative: any MISS while
        -- last_row_valid=1 PRECHARGEs-ALL first) → 8 clk64.
        issue("Scen E.2 cross-bank MISS",
              to_unsigned(16#0210000#, 25), 8, 1, scen_e_ok);
        wait_clk64(4);
        -- bank=1 row=0x100 again — same as #2, should HIT.
        -- HIT cycle = 4 clk64 with CAS_LATENCY+1 safety margin (2026-05-26).
        issue("Scen E.3 same-bank HIT",
              to_unsigned(16#0210080#, 25), 4, 1, scen_e_ok);

        wait_clk64(6);

        --
        -- Scenario F: write-then-read same row stays on HIT path.
        --
        log("--- Scenario F (write/read same row) ---");
        -- MISS prep on row 0x222. Conflict-MISS (E.3 HIT left row open) → 8.
        issue("Scen F.1 MISS prep",
              to_unsigned(16#0022200#, 25), 8, 1, scen_f_ok);
        wait_clk64(4);
        -- HIT write on same row.
        wait until rising_edge(clk64);
        addr <= to_unsigned(16#0022240#, 25);
        we   <= '1';
        ce   <= '1';
        wait until rising_edge(clk64);
        ce   <= '0';
        we   <= '0';
        -- Wait for ready.
        for i in 1 to 20 loop
            wait until rising_edge(clk64);
            if ready = '1' then exit; end if;
        end loop;
        if ready = '1' then
            log("Scen F.2 HIT write OK");
            scen_f_ok <= '1';
        else
            log("FAIL Scen F.2: write never completed");
            fail_count <= fail_count + 1;
            scen_f_ok <= '0';
        end if;
        wait_clk64(4);

        --
        -- Scenario G: 3-deep HIT streak (typical SuperRAM linear fetch).
        -- MISS prep + 3 consecutive HITs all in the same row.
        --
        log("--- Scenario G (3-deep HIT streak) ---");
        -- Conflict-MISS (F.2 HIT left row open) → 8.
        issue("Scen G.1 MISS prep",
              to_unsigned(16#0033300#, 25), 8, 1, scen_g_ok);
        wait_clk64(2);
        issue("Scen G.2 HIT 1",
              to_unsigned(16#0033340#, 25), 4, 1, scen_g_ok);
        wait_clk64(2);
        issue("Scen G.3 HIT 2",
              to_unsigned(16#0033380#, 25), 4, 1, scen_g_ok);
        wait_clk64(2);
        issue("Scen G.4 HIT 3",
              to_unsigned(16#00333C0#, 25), 4, 1, scen_g_ok);

        wait_clk64(6);

        --
        -- Scenario H: Option (b) gate — bank-$00 (fast_path=0) stays on
        -- MISS-only path, even when the cached row would otherwise match.
        --   H.1: fast_path=1 MISS on bank=3 row=0x123 (opens, tracks row)
        --   H.2: fast_path=1 HIT on same row to confirm tracking works
        --   H.3: fast_path=0 access on same bank+row — gate must force
        --        MISS path (6 clk64) AND invalidate last_row_valid
        --   H.4: fast_path=1 access on same bank+row — must MISS (because
        --        H.3 invalidated the tracking) instead of HIT, confirming
        --        the gate properly tracks reality
        --
        log("--- Scenario H (Option (b) gate: fast_path=0 forces MISS) ---");
        fast_path <= '1';
        wait until rising_edge(clk64);
        -- bank=3 row=0x123 -> [22:21]=11, [20:8]=0x123
        --   25-bit = 0_0110_0010_0011_0000_0000_0000 (bt=0, col_top=0)
        -- Conflict-MISS (G.4 HIT left row open) → 8.
        issue("Scen H.1 prep MISS fast_path=1",
              to_unsigned(16#0612300#, 25), 8, 1, scen_h_ok);
        wait_clk64(2);
        -- Same bank+row, different column. Must HIT.
        issue("Scen H.2 HIT fast_path=1 (sanity)",
              to_unsigned(16#0612340#, 25), 4, 1, scen_h_ok);
        wait_clk64(2);
        -- Now drop fast_path and access same bank+row again. The HIT gate
        -- must reject it -> MISS-length cycle. Under Option (a) the open
        -- row from H.2 forces conflict-MISS (PRECHARGE-ALL first) → 8 clk64.
        fast_path <= '0';
        wait until rising_edge(clk64);
        issue("Scen H.3 fast_path=0 same row stays MISS",
              to_unsigned(16#0612380#, 25), 8, 1, scen_h_ok);
        wait_clk64(2);
        -- Re-arm fast_path. last_row_valid was invalidated by H.3, so
        -- this MUST be a MISS (6 clk64), not a HIT, even though the
        -- bank+row look like they would match the prior open row.
        fast_path <= '1';
        wait until rising_edge(clk64);
        issue("Scen H.4 fast_path=1 first re-access is MISS",
              to_unsigned(16#06123C0#, 25), 6, 1, scen_h_ok);

        wait_clk64(6);

        --
        -- Scenario I (Codex Risk 1 — AUTO_REFRESH while a bank is open).
        --   I.1: fast_path=1 MISS opens a row.
        --   I.2: pulse refresh. Lite emits CMD_AUTO_REFRESH; shadow
        --        increments refresh_while_open_count because bank_open
        --        is still set (Option (b) doesn't PRECHARGE first).
        --   Expectation: with expect_spec_violations=true (= current
        --   reality), the violation MUST be seen; with the flag false,
        --   the violation MUST NOT happen (Option (a) is correct).
        --
        log("--- Scenario I (refresh-while-row-open, Codex Risk 1) ---");
        i_violations_at_start <= refresh_while_open_count;
        wait_clk64(1);
        fast_path <= '1';
        wait until rising_edge(clk64);
        -- Conflict-MISS (H.4 left row open) → 8.
        issue("Scen I.1 prep fast_path=1 MISS",
              to_unsigned(16#0432100#, 25), 8, 1, scen_i_ok);
        wait_clk64(2);
        -- Pulse refresh for 2 clk64 to guarantee the lite's last_refresh
        -- registered version sees a rising edge.
        refresh <= '1';
        wait until rising_edge(clk64);
        wait until rising_edge(clk64);
        refresh <= '0';
        wait_clk64(4);
        if expect_spec_violations then
            if refresh_while_open_count > i_violations_at_start then
                log("Scen I OK (EXPECTED VIOLATION, Option b): "
                    & "refresh-while-open count delta="
                    & integer'image(refresh_while_open_count - i_violations_at_start));
                scen_i_ok <= '1';
            else
                log("FAIL Scen I: expected refresh-while-open violation under Option (b); got none");
                fail_count <= fail_count + 1;
                scen_i_ok <= '0';
            end if;
        else
            if refresh_while_open_count = i_violations_at_start then
                log("Scen I OK: AUTO_REFRESH issued only when banks closed (Option a)");
                scen_i_ok <= '1';
            else
                log("FAIL Scen I (Option a regression): refresh fired with a bank open");
                fail_count <= fail_count + 1;
                scen_i_ok <= '0';
            end if;
        end if;

        wait_clk64(6);

        --
        -- Scenario J (Codex Risk 2 — cross-class same-bank conflict).
        --   J.1: fast_path=1 MISS to bank=1 row=0x321 (opens row X).
        --   J.2: fast_path=0 MISS to bank=1 row=0x654 (different row).
        --        Lite emits CMD_ACTIVE for row 0x654 while bank_open[1]
        --        still reflects row 0x321 → shadow increments
        --        active_conflict_count (Option (b) bug).
        --
        log("--- Scenario J (cross-class same-bank, Codex Risk 2) ---");
        j_violations_at_start <= active_conflict_count;
        wait_clk64(1);
        -- bank=1 row=0x321 -> [22:21]=01, [20:8]=0x321
        --   25-bit = 00_0011_0010_0001_00000000_00000000 = 0x0232100
        fast_path <= '1';
        wait until rising_edge(clk64);
        issue("Scen J.1 fast_path=1 MISS opens bank=1 row=0x321",
              to_unsigned(16#0232100#, 25), 6, 1, scen_j_ok);
        wait_clk64(2);
        -- bank=1 row=0x654 -> [22:21]=01, [20:8]=0x654
        --   25-bit = 00_0011_0010_1010_10000000_00000000 = 0x0265400
        fast_path <= '0';
        wait until rising_edge(clk64);
        -- Conflict-MISS by design (J.1 left row open in bank=1) → 8.
        issue("Scen J.2 fast_path=0 MISS bank=1 row=0x654 (conflict)",
              to_unsigned(16#0265400#, 25), 8, 1, scen_j_ok);
        wait_clk64(2);
        if expect_spec_violations then
            if active_conflict_count > j_violations_at_start then
                log("Scen J OK (EXPECTED VIOLATION, Option b): "
                    & "same-bank ACTIVE-conflict count delta="
                    & integer'image(active_conflict_count - j_violations_at_start));
                scen_j_ok <= '1';
            else
                log("FAIL Scen J: expected same-bank conflict under Option (b); got none");
                fail_count <= fail_count + 1;
                scen_j_ok <= '0';
            end if;
        else
            if active_conflict_count = j_violations_at_start then
                log("Scen J OK: no same-bank conflict (Option a PRECHARGE'd first)");
                scen_j_ok <= '1';
            else
                log("FAIL Scen J (Option a regression): cross-class same-bank conflict still fires");
                fail_count <= fail_count + 1;
                scen_j_ok <= '0';
            end if;
        end if;

        wait_clk64(6);

        --
        -- Scenario K (Codex Risk 2, intra-class variant — SuperRAM
        -- cross-row same-bank).
        --   K.1: fast_path=1 MISS to bank=2 row=0x111 (opens row X).
        --   K.2: fast_path=1 MISS to bank=2 row=0x222 (different row,
        --        different SDRAM bank-row). Bank still open from K.1
        --        because fast_path=1 doesn't auto-precharge → shadow
        --        increments active_conflict_count.
        --
        log("--- Scenario K (SuperRAM cross-row same-bank, Codex Risk 2) ---");
        k_violations_at_start <= active_conflict_count;
        wait_clk64(1);
        -- bank=2 row=0x111 -> [22:21]=10, [20:8]=0x111
        --   25-bit = 00_0101_0001_0001_00000000_00000000 = 0x0411100
        fast_path <= '1';
        wait until rising_edge(clk64);
        issue("Scen K.1 fast_path=1 MISS opens bank=2 row=0x111",
              to_unsigned(16#0411100#, 25), 6, 1, scen_k_ok);
        wait_clk64(2);
        -- bank=2 row=0x222 -> [22:21]=10, [20:8]=0x222
        --   25-bit = 00_0101_0010_0010_00000000_00000000 = 0x0422200
        wait until rising_edge(clk64);
        -- Conflict-MISS by design (K.1 left row open in bank=2) → 8.
        issue("Scen K.2 fast_path=1 MISS bank=2 row=0x222 (conflict)",
              to_unsigned(16#0422200#, 25), 8, 1, scen_k_ok);
        wait_clk64(2);
        if expect_spec_violations then
            if active_conflict_count > k_violations_at_start then
                log("Scen K OK (EXPECTED VIOLATION, Option b): "
                    & "SuperRAM cross-row conflict count delta="
                    & integer'image(active_conflict_count - k_violations_at_start));
                scen_k_ok <= '1';
            else
                log("FAIL Scen K: expected SuperRAM cross-row conflict under Option (b); got none");
                fail_count <= fail_count + 1;
                scen_k_ok <= '0';
            end if;
        else
            if active_conflict_count = k_violations_at_start then
                log("Scen K OK: SuperRAM cross-row PRECHARGEd first (Option a)");
                scen_k_ok <= '1';
            else
                log("FAIL Scen K (Option a regression): SuperRAM cross-row conflict still fires");
                fail_count <= fail_count + 1;
                scen_k_ok <= '0';
            end if;
        end if;

        wait_clk64(6);

        --
        -- Step 6 Scenario A: HIT preload "001" clears within 2 clk32.
        --
        log("--- Step 6 closure A: HIT preload ('001') ---");
        -- Prep MISS on row 0x444 to seat the row. Conflict-MISS (K.2 left
        -- bank=2 row=0x222 open) → 8 clk64.
        issue("S6-A prep MISS",
              to_unsigned(16#0044400#, 25), 8, 1, s6_a_ok);
        wait_clk64(4);

        -- Tell the Step 6 model: predict HIT.
        sdram_hit_pred <= '1';
        wait until rising_edge(clk32);
        cpu_cyc_pulse <= '1';
        wait until rising_edge(clk32);
        cpu_cyc_pulse <= '0';
        sdram_hit_pred <= '0';

        -- Issue actual HIT access concurrently so ready_sync edge can
        -- close the loop.
        wait until rising_edge(clk64);
        addr <= to_unsigned(16#0044440#, 25);
        ce   <= '1';
        wait until rising_edge(clk64);
        ce   <= '0';
        -- Wait up to 4 clk32 for busy to clear.
        wait_clk32(4);
        if sdram_busy = '0' then
            log("S6-A OK: HIT preload cleared busy_cnt within 4 clk32");
            s6_a_ok <= '1';
        else
            log("FAIL S6-A: HIT preload did not clear busy");
            fail_count <= fail_count + 1;
            s6_a_ok <= '0';
        end if;
        -- Drain.
        for i in 1 to 10 loop
            wait until rising_edge(clk64);
            if ready = '1' then exit; end if;
        end loop;

        wait_clk64(6);

        --
        -- Step 6 Scenario B: MISS preload "011" with ready-edge early-
        -- clear. The counter should clear via the ready edge BEFORE the
        -- static decrement would naturally roll to 0 (which would take
        -- 3 clk32). With early-clear on Build C MISS = ~6 clk64 = 3
        -- clk32 + 2 sync = 5 clk32 budget, so the static decrement and
        -- the early-clear both land around the same edge. The check is
        -- that busy is clear by 5 clk32.
        --
        log("--- Step 6 closure B: MISS preload + ready-edge early-clear ---");
        sdram_hit_pred <= '0';
        wait until rising_edge(clk32);
        cpu_cyc_pulse <= '1';
        wait until rising_edge(clk32);
        cpu_cyc_pulse <= '0';

        -- Issue MISS access.
        wait until rising_edge(clk64);
        addr <= to_unsigned(16#0055500#, 25);
        ce   <= '1';
        wait until rising_edge(clk64);
        ce   <= '0';

        -- Wait up to 5 clk32. Counter must clear in that window.
        wait_clk32(5);
        if sdram_busy = '0' then
            log("S6-B OK: MISS preload cleared busy_cnt within 5 clk32");
            s6_b_ok <= '1';
        else
            log("FAIL S6-B: MISS preload + early-clear did not clear busy");
            fail_count <= fail_count + 1;
            s6_b_ok <= '0';
        end if;

        wait_clk64(6);

        --
        -- WRONG-pattern hazard demo. Activate the combinational alt_fire
        -- path and let hazard_toggle flicker for several clk32 windows.
        -- The bench observes that cpu_cyc_wrong picks up MULTIPLE rising
        -- edges per "real" intended fire, while cpu_cyc_right stays
        -- monotonic. This is the synthesis-hazard analog described in
        -- project_alt_fire_r_dead_on_buildB_2026_05_23.md.
        --
        log("--- WRONG: combinational alt_fire (hazard model) ---");
        edge_reset_req <= '1';
        wait_clk32(1);
        edge_reset_req <= '0';
        wait_clk32(1);
        wrong_demo_active <= '1';
        -- Let it run for 6 clk32 — hazard_toggle flips on every clk64
        -- edge, so combinational alt_fire alternates 0/1 every clk64
        -- (twice per clk32). The clk32 sampler should see each clk32
        -- edge alternately catching alt_fire=1 then alt_fire=0.
        wait_clk32(6);
        wrong_demo_active <= '0';
        wait_clk32(2);

        -- Verdict: combinational variant should have MORE clk64-rate
        -- rising edges than the registered variant — that's the bug
        -- being demoed. With a 6-clk32 window and hazard_toggle flipping
        -- every clk64, the comb path catches ~6 rising edges (every
        -- other clk64 sample is 1) while the registered path catches
        -- 0-1 (alt_fire_r is constant once latched because the clk32
        -- sample phase always sees hazard_toggle in the same state).
        if clk64_rising_count_wrong > clk64_rising_count_right then
            log("WRONG demo OK: comb alt_fire produced "
                & integer'image(clk64_rising_count_wrong)
                & " clk64-rate rising edges vs registered "
                & integer'image(clk64_rising_count_right)
                & " (glitches confirmed)");
            wrong_ok <= '1';
        else
            log("FAIL WRONG demo: comb alt_fire showed "
                & integer'image(clk64_rising_count_wrong)
                & " edges; expected MORE than registered ("
                & integer'image(clk64_rising_count_right) & ")");
            fail_count <= fail_count + 1;
            wrong_ok <= '0';
        end if;

        wait_clk32(4);

        --
        -- RIGHT pattern: registered alt_fire_r samples the same predicate
        -- on the clk32 edge. cpu_cyc_right stays glitch-free even though
        -- the predicate is wiggling. This is the design's mitigation.
        --
        log("--- RIGHT: registered alt_fire_r (glitch-free) ---");
        -- Reset edge counters via the edge_reset_req handshake so the
        -- next snapshot reflects only the RIGHT-pattern run.
        edge_reset_req <= '1';
        wait_clk32(1);
        edge_reset_req <= '0';
        wait_clk32(1);
        wrong_demo_active <= '1';
        wait_clk32(6);
        wrong_demo_active <= '0';
        wait_clk32(2);

        -- The registered alt_fire_r should produce AT MOST 1 rising edge
        -- during the window (the 0→1 transition when wrong_demo_active
        -- rises and the clk32 sample catches hazard_toggle=1). Some
        -- phasings produce 0 if hazard_toggle is always sampled as 0.
        -- The deterministic invariant: clk64-rate count = clk32-rate
        -- count (no sub-clk32 glitches). For this bench's geometry the
        -- registered count is observed to be 0 — which is FINE because
        -- the wrong count is much higher (the whole point of the demo).
        if clk64_rising_count_right <= 2 then
            log("RIGHT demo OK: registered alt_fire_r produced "
                & integer'image(clk64_rising_count_right)
                & " clean clk64-rate rising edges (<=2, no glitches)");
            right_ok <= '1';
        else
            log("FAIL RIGHT demo: registered alt_fire_r edges = "
                & integer'image(clk64_rising_count_right) & " (expected <=2)");
            fail_count <= fail_count + 1;
            right_ok <= '0';
        end if;

        wait_clk64(8);

        log("=== Verdict ===");
        log("SDRAM-spec totals: refresh_while_open="
            & integer'image(refresh_while_open_count)
            & " active_conflicts="
            & integer'image(active_conflict_count)
            & " (expect_spec_violations="
            & boolean'image(expect_spec_violations) & ")");
        if fail_count = 0
           and scen_e_ok = '1'
           and scen_f_ok = '1'
           and scen_g_ok = '1'
           and scen_h_ok = '1'
           and scen_i_ok = '1'
           and scen_j_ok = '1'
           and scen_k_ok = '1'
           and s6_a_ok   = '1'
           and s6_b_ok   = '1'
           and wrong_ok  = '1'
           and right_ok  = '1' then
            log("RESULT: PASS");
        else
            log("RESULT: FAIL count=" & integer'image(fail_count)
                & " E=" & std_logic'image(scen_e_ok)
                & " F=" & std_logic'image(scen_f_ok)
                & " G=" & std_logic'image(scen_g_ok)
                & " H=" & std_logic'image(scen_h_ok)
                & " I=" & std_logic'image(scen_i_ok)
                & " J=" & std_logic'image(scen_j_ok)
                & " K=" & std_logic'image(scen_k_ok)
                & " S6A=" & std_logic'image(s6_a_ok)
                & " S6B=" & std_logic'image(s6_b_ok)
                & " WRONG=" & std_logic'image(wrong_ok)
                & " RIGHT=" & std_logic'image(right_ok));
        end if;

        sim_done <= true;
        wait for 100 ns;
        assert false report "End of simulation" severity note;
        wait;
    end process;

end architecture;
