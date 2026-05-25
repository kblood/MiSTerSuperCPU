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
        -- Option (b) gate (Milestone A, 2026-05-26): '1' = SuperRAM access.
        -- Mirrors sdram_pm.v's fast_path port. When '0', row tracking is
        -- not updated and the HIT path is forced off — controller stays on
        -- MISS-only (= Build B baseline). Default '1' to keep legacy bench
        -- scenarios that don't drive this port behaving as before.
        fast_path  : in  std_logic := '1';
        ready      : out std_logic;
        data_valid : out std_logic;
        -- bench debug: 1 = current cycle is on the HIT (3-clk) fast path
        dbg_hit_path : out std_logic;
        --
        -- SDRAM command observation (Step 1 of post-Codex Option (a)
        -- plan, 2026-05-26). The lite model emits a 1-clk pulse for each
        -- SDRAM-spec-significant command it would issue, plus the bank /
        -- row context where applicable. The bench snoops these to
        -- maintain a per-bank open-row shadow and assert SDRAM-spec
        -- legality (no ACTIVE on already-open bank with different row;
        -- no AUTO_REFRESH while any bank open). These ports are
        -- diagnostic-only — the controller's data path is unaffected.
        --
        -- For the current Option (b) lite model:
        --   cmd_active_pulse   : fires at every MISS ce-edge.
        --   cmd_precharge_pulse: NEVER fires (Option (b) has no PRECHARGE
        --                        FSM — that's what Codex Risk 1+2 named).
        --   cmd_refresh_pulse  : fires on refresh rising edge.
        --
        -- Once Option (a) lands, cmd_precharge_pulse will fire on
        -- conflict-MISS and before-AUTO_REFRESH-while-open.
        cmd_active_pulse     : out std_logic;
        cmd_active_bank      : out unsigned(1 downto 0);
        cmd_active_row       : out unsigned(12 downto 0);
        cmd_precharge_pulse  : out std_logic;
        cmd_precharge_all    : out std_logic;          -- '1' if A10=1 (all banks)
        cmd_precharge_bank   : out unsigned(1 downto 0); -- valid when _all=0
        cmd_refresh_pulse    : out std_logic
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
    -- Latched fast_path for the MISS cycle — drives the implicit
    -- auto-precharge emission at burst end when fast_path=0 (matches
    -- sdram_pm.v's `miss_fastpath` register controlling A10).
    signal cycle_miss_fastpath : std_logic := '0';
    -- Option (a) (2026-05-26): latched at ce-edge. '1' means this MISS
    -- needs a PRECHARGE-ALL before its ACTIVE. Shifts cycle length from
    -- 6 to 8 clk64 because of the 2-clk tRP wait. Bench shadow watches
    -- cmd_precharge_pulse to clear bank_open before cmd_active_pulse
    -- re-opens it.
    signal cycle_needs_precharge : std_logic := '0';
    -- Latched bank+row for the delayed cmd_active_pulse on conflict
    -- MISS (emitted at q=2 instead of ce-edge).
    signal cycle_active_bank : unsigned(1 downto 0)  := (others => '0');
    signal cycle_active_row  : unsigned(12 downto 0) := (others => '0');

    -- Refresh sub-state (Option a). When refresh fires with a row
    -- tracked open, the lite first emits cmd_precharge_pulse_r(_all)
    -- on the refresh edge, sets refresh_pending, and emits
    -- cmd_refresh_pulse_r 2 clk64 later when refresh_wait reaches 0.
    signal refresh_pending_r : std_logic := '0';
    signal refresh_wait_r    : unsigned(1 downto 0) := (others => '0');

    -- Conflict-MISS sample edge (q=7 vs q=5 for non-conflict).
    constant CONFLICT_SAMPLE_Q : unsigned(2 downto 0) := "111";  -- q=7

    -- Per the design doc §2.2: MISS sample at q=5 (v6 shortcut), HIT sample
    -- at q=3 (was q=2; bumped 2026-05-26 to mirror the +1 safety margin
    -- the MISS path inherits — see sdram_pm.v STATE_READ_HIT comment).
    -- Ready rises one clk64 after sample (when q returns to 0).
    constant MISS_SAMPLE_Q : unsigned(2 downto 0) := "101";  -- q=5
    constant HIT_SAMPLE_Q  : unsigned(2 downto 0) := "011";  -- q=3

    signal ready_r       : std_logic := '1';
    signal data_valid_r  : std_logic := '0';

    -- SDRAM-command observation registers (Step 1, 2026-05-26).
    signal cmd_active_pulse_r    : std_logic := '0';
    signal cmd_active_bank_r     : unsigned(1 downto 0) := (others => '0');
    signal cmd_active_row_r      : unsigned(12 downto 0) := (others => '0');
    signal cmd_precharge_pulse_r : std_logic := '0';
    signal cmd_precharge_all_r   : std_logic := '0';
    signal cmd_precharge_bank_r  : unsigned(1 downto 0) := (others => '0');
    signal cmd_refresh_pulse_r   : std_logic := '0';
begin

    ready        <= ready_r;
    data_valid   <= data_valid_r;
    dbg_hit_path <= cycle_is_hit when in_flight = '1' else '0';

    cmd_active_pulse    <= cmd_active_pulse_r;
    cmd_active_bank     <= cmd_active_bank_r;
    cmd_active_row      <= cmd_active_row_r;
    cmd_precharge_pulse <= cmd_precharge_pulse_r;
    cmd_precharge_all   <= cmd_precharge_all_r;
    cmd_precharge_bank  <= cmd_precharge_bank_r;
    cmd_refresh_pulse   <= cmd_refresh_pulse_r;

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
                cycle_needs_precharge <= '0';
                in_flight      <= '0';
                ready_r        <= '1';
                data_valid_r   <= '0';
                cmd_active_pulse_r    <= '0';
                cmd_precharge_pulse_r <= '0';
                cmd_precharge_all_r   <= '0';
                cmd_refresh_pulse_r   <= '0';
                refresh_pending_r     <= '0';
                refresh_wait_r        <= (others => '0');
            else
                last_ce      <= ce;
                last_refresh <= refresh;

                -- Default: all command pulses low; rise only on the edge
                -- where the corresponding SDRAM command would issue.
                cmd_active_pulse_r    <= '0';
                cmd_precharge_pulse_r <= '0';
                cmd_refresh_pulse_r   <= '0';

                -- Refresh handler (Option a):
                --   If a row is tracked open, emit PRECHARGE-ALL first
                --   and defer CMD_AUTO_REFRESH by tRP (2 clk64) via
                --   refresh_pending_r + refresh_wait_r. Otherwise fire
                --   AUTO_REFRESH directly.
                if refresh = '1' and last_refresh = '0' then
                    if last_row_valid = '1' then
                        cmd_precharge_pulse_r <= '1';
                        cmd_precharge_all_r   <= '1';  -- A10=1, all-bank
                        refresh_pending_r     <= '1';
                        refresh_wait_r        <= to_unsigned(2, 2);
                    else
                        cmd_refresh_pulse_r <= '1';
                    end if;
                    last_row_valid <= '0';
                elsif refresh_pending_r = '1' then
                    if refresh_wait_r = to_unsigned(0, 2) then
                        cmd_refresh_pulse_r <= '1';
                        refresh_pending_r   <= '0';
                    else
                        refresh_wait_r <= refresh_wait_r - 1;
                    end if;
                end if;

                -- ce-edge launches a new cycle if controller is idle (q=0
                -- and ~in_flight). Subsequent ce-edges during in-flight
                -- are ignored — matches sdram_pm.v's first-edge-wins.
                if ce = '1' and last_ce = '0'
                   and in_flight = '0' and q = "000" then

                    -- Decide HIT vs MISS at the ce-edge. Option (b) gate:
                    -- HIT only fires when fast_path = '1' (SuperRAM).
                    if fast_path = '1'
                       and last_row_valid = '1'
                       and bank_of(addr) = last_bank
                       and row_of(addr)  = last_row then
                        will_hit := '1';
                    else
                        will_hit := '0';
                    end if;
                    cycle_is_hit <= will_hit;
                    -- Option (a) conflict detection — captured here so
                    -- the cycle's length is deterministic from start.
                    if will_hit = '0' and last_row_valid = '1' then
                        cycle_needs_precharge <= '1';
                    else
                        cycle_needs_precharge <= '0';
                    end if;
                    in_flight    <= '1';
                    ready_r      <= '0';
                    data_valid_r <= '0';

                    q             <= "001";
                    if will_hit = '0' then
                        -- Latch bank/row for the cmd_active emission.
                        cycle_active_bank   <= bank_of(addr);
                        cycle_active_row    <= row_of(addr);
                        cycle_miss_fastpath <= fast_path;
                        if last_row_valid = '1' then
                            -- Conflict MISS — Option (a): emit
                            -- CMD_PRECHARGE-ALL FIRST. cmd_active fires
                            -- 2 clk64 later at q=2 (see q-advance below).
                            cmd_precharge_pulse_r <= '1';
                            cmd_precharge_all_r   <= '1';
                        else
                            -- Non-conflict MISS — emit cmd_active at
                            -- ce-edge directly (no precharge needed).
                            cmd_active_pulse_r <= '1';
                            cmd_active_bank_r  <= bank_of(addr);
                            cmd_active_row_r   <= row_of(addr);
                        end if;
                    end if;
                    -- Row-tracking lifecycle (matches sdram_pm.v):
                    --   - fast_path='1' MISS: row stays open after burst
                    --     (A10=0), record bank/row for future HIT.
                    --   - fast_path='0' MISS: A10=1 closes the row, so
                    --     invalidate last_row_valid to avoid phantom HIT.
                    if fast_path = '1' then
                        last_bank      <= bank_of(addr);
                        last_row       <= row_of(addr);
                        last_row_valid <= '1';
                    else
                        last_row_valid <= '0';
                    end if;

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
                        -- MISS path. Cycle length depends on whether the
                        -- MISS conflicts with an already-open row:
                        --   non-conflict: 6 clk64 (sample at q=5)
                        --   conflict    : 8 clk64 (sample at q=7) — PRE-ALL
                        --                 emitted at ce-edge, then tRP=2 clk
                        --                 wait, then CMD_ACTIVE at q=2,
                        --                 R/W at q=4, sample at q=7.
                        if cycle_needs_precharge = '1' then
                            if q = "010" then
                                -- Delayed CMD_ACTIVE after tRP.
                                cmd_active_pulse_r <= '1';
                                cmd_active_bank_r  <= cycle_active_bank;
                                cmd_active_row_r   <= cycle_active_row;
                                q <= q + 1;
                            elsif q = CONFLICT_SAMPLE_Q then
                                data_valid_r <= '1';
                                q            <= "000";
                                ready_r      <= '1';
                                in_flight    <= '0';
                                if cycle_miss_fastpath = '0' then
                                    cmd_precharge_pulse_r <= '1';
                                    cmd_precharge_all_r   <= '0';
                                    cmd_precharge_bank_r  <= cycle_active_bank;
                                end if;
                            else
                                q <= q + 1;
                            end if;
                        else
                            -- Non-conflict MISS: q runs 0..5 (sample at 5).
                            if q = MISS_SAMPLE_Q then
                                data_valid_r <= '1';
                                q            <= "000";
                                ready_r      <= '1';
                                in_flight    <= '0';
                                -- Implicit auto-precharge emission. When
                                -- cycle_miss_fastpath='0' the controller's
                                -- READ/WRITE at q=2 was issued with A10=1
                                -- (auto-precharge ON), so the row closes
                                -- coincident with the burst-end at q=5. The
                                -- bench's per-bank shadow needs to see this
                                -- as a PRECHARGE on that bank.
                                if cycle_miss_fastpath = '0' then
                                    cmd_precharge_pulse_r <= '1';
                                    cmd_precharge_all_r   <= '0';
                                    cmd_precharge_bank_r  <= cmd_active_bank_r;
                                end if;
                            else
                                q <= q + 1;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
