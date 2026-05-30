-- turbo_throughput_tb.vhd
--
-- Two-clock-domain throughput + correctness bench for the SuperCPU bus
-- arbiter. Wires the REAL arbiter logic (cpu_arb_model, extracted verbatim
-- from fpga64_sid_iec.vhd) on clk32 to the validated Build-C SDRAM model
-- (sdram_pm_lite) on clk64, through the same 2-FF ready sync the silicon uses.
--
-- It answers the two questions iter-4 left open with NUMBERS:
--   (1) THROUGHPUT — CPU accesses launched per microsecond = effective MHz.
--   (2) CORRECTNESS — does the arbiter ever overwrite the SDRAM read latch
--       (start a new access) before the prior access's REAL data_valid? That
--       is the stale-read hazard that wedged HW (Doom BRK $00:000A).
--
-- Configure the experiment via top-level generics (set by the run script):
--   G_ALT_SLOTS, G_HIT_MODE, G_BUSY_FROM_READY  -> arbiter knobs
--   G_STRIDE  -> bytes between consecutive CPU accesses. 1 = tight sequential
--                (≈255/256 row hits); 256 = every access a new row (all MISS).
--   G_US      -> microseconds (wheel rotations) to measure over.
--
-- Baseline assertion: defaults (no alt, hit_mode 0) MUST report ~4.0 MHz with
-- 0 stale reads — that validates the model against known silicon before any
-- experimental config is believed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity turbo_throughput_tb is
    generic (
        G_ALT_SLOTS       : boolean := false;
        G_HIT_MODE        : integer := 0;
        G_BUSY_FROM_READY : boolean := false;
        G_SLOT3           : boolean := false;  -- 3-clk32 grant cadence (CPU0/3/6/9/C/F)
        -- G_NO_ROWTRACK (2026-05-30): model the DEPLOYED sdram_pm.v, which has
        -- NO fast_path port and auto-precharges every access (A10=1) -> never
        -- tracks an open row -> EVERY access is the uniform non-conflict 6-clk64
        -- MISS. Forces sdram_pm_lite.fast_path='0' unconditionally so no row is
        -- ever held open and the conflict-MISS (q=7, 8 clk64) path can't fire.
        -- This is the faithful controller for the G_SLOT3 lever; the legacy
        -- lite default (fast_path<-scpu_fast) models the page-mode Build-C
        -- row-tracking controller, which is NOT what ships.
        G_NO_ROWTRACK     : boolean := false;
        G_STRIDE          : integer := 1;
        G_REFRESH_PERIOD  : integer := 0;   -- 0=off; else clk64 cycles between refresh pulses (async row-close stress)
        G_INTERLEAVE      : boolean := false; -- true=alternate SuperRAM(fast)/bank-$00 accesses (Doom-loader shape; forces conflict-MISS)
        G_US              : integer := 1000
    );
end entity;

architecture sim of turbo_throughput_tb is

    constant CLK64_HALF : time := 7.8125 ns;   -- 64 MHz
    -- clk32 is built by dividing clk64 so the two are exactly phase-aligned.

    signal clk64 : std_logic := '0';
    signal clk32 : std_logic := '0';
    signal reset : std_logic := '1';

    -- CPU request
    signal cpu_addr  : unsigned(24 downto 0) := (others => '0');
    signal scpu_fast : std_logic := '1';
    signal acc_index : unsigned(31 downto 0) := (others => '0');  -- # accesses launched

    -- arbiter <-> sdram
    signal cpu_cyc          : std_logic;
    signal access_done      : std_logic;
    signal pred_hit         : std_logic;
    signal sdram_ready      : std_logic;
    signal sdram_data_valid : std_logic;
    signal dbg_hit_path     : std_logic;
    signal ctrl_hit_in      : std_logic := '0';

    -- sdram_pm_lite command observation (for the mode-2 single-tracker shadow)
    signal cmd_active_pulse    : std_logic;
    signal cmd_active_bank     : unsigned(1 downto 0);
    signal cmd_active_row      : unsigned(12 downto 0);
    signal cmd_precharge_pulse : std_logic;
    signal cmd_precharge_all   : std_logic;
    signal cmd_precharge_bank  : unsigned(1 downto 0);
    signal cmd_refresh_pulse   : std_logic;

    -- mode-2 shadow of the controller's open row (slaved to its cmd stream)
    signal shadow_valid : std_logic := '0';
    signal shadow_bank  : unsigned(1 downto 0)  := (others => '0');
    signal shadow_row   : unsigned(12 downto 0) := (others => '0');

    -- measurement
    signal cyc_count   : natural := 0;
    signal hit_count   : natural := 0;
    signal stale_count : natural := 0;
    signal sim_done    : boolean := false;

    -- correctness tracking (clk64 domain): a new ce (cpu_cyc rising edge) that
    -- asserts while sdram_ready='0' = the controller is mid-cycle and will
    -- silently DROP this access (ce-edge ignored during in_flight). That is
    -- exactly the dual-tracker hazard that corrupted Doom's REU->SuperRAM
    -- stream. ready is the controller's own "safe to assert new ce" contract.
    signal last_cpu_cyc  : std_logic := '0';

    -- fixed top 4 bits: bit24=1 (SuperRAM region), bit23=0, bank(22:21)="01".
    constant ADDR_TOP4 : std_logic_vector(3 downto 0) := "1001";
    signal offset21 : unsigned(20 downto 0);

    -- async refresh stress: a refresh pulse the arbiter is UNAWARE of, which
    -- closes the controller's open row mid-CPU-window (faithful model of the
    -- REU/DMA-stolen cycle that closed the row during Doom's transfer). The
    -- arbiter's private predictor (mode 1) cannot see it -> divergence; the
    -- single-tracker shadow (mode 2) follows cmd_refresh -> stays correct.
    signal refresh     : std_logic := '0';
    signal refresh_cnt : integer := 0;

    -- fast_path into the SDRAM model: forced '0' (no row tracking = deployed
    -- controller) when G_NO_ROWTRACK, else the legacy scpu_fast (row-tracking
    -- Build-C lite model).
    signal sdram_fast_path : std_logic;

begin

    sdram_fast_path <= '0' when G_NO_ROWTRACK else scpu_fast;

    --------------------------------------------------------------------
    -- Clocks: clk64 free-running, clk32 = clk64/2, phase-aligned.
    --------------------------------------------------------------------
    clk64_gen : process
    begin
        while not sim_done loop
            clk64 <= '0'; wait for CLK64_HALF;
            clk64 <= '1'; wait for CLK64_HALF;
        end loop;
        wait;
    end process;

    clk32_div : process(clk64)
    begin
        if rising_edge(clk64) then
            clk32 <= not clk32;   -- toggles each clk64 rise -> 32 MHz, aligned
        end if;
    end process;

    --------------------------------------------------------------------
    -- CPU address generator: sequential walk with configurable stride.
    -- A new address is presented after each launched access (cpu_cyc).
    --
    -- G_INTERLEAVE models the REAL Doom-loader / 6502 access shape: odd
    -- accesses target bank-$00 (fast_path=0) instead of SuperRAM. A bank-$00
    -- access after a SuperRAM access is a different bank+row while the SuperRAM
    -- row is still tracked open -> the controller's CONFLICT-MISS path fires
    -- (PRECHARGE-ALL + ACTIVE + R/W, sample at q=7 = 1 clk64-pair later than a
    -- plain MISS). The pure-sequential pattern (default) NEVER exercises this,
    -- which is why mode-2 showed 0 stale in sim yet BRK'd on HW. With interleave
    -- on, the correctness monitor sees the conflict-MISS data arrive after the
    -- arbiter's fixed-timing sample -> stale, faithfully reproducing the HW bug.
    --------------------------------------------------------------------
    offset21  <= resize(acc_index * to_unsigned(G_STRIDE, 16), 21);
    cpu_addr  <= (unsigned'("0000") & offset21)
                     when (G_INTERLEAVE and acc_index(0) = '1')
                 else unsigned(ADDR_TOP4) & offset21;
    scpu_fast <= '0' when (G_INTERLEAVE and acc_index(0) = '1') else '1';

    cpu_gen : process(clk32)
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                acc_index <= (others => '0');
            elsif cpu_cyc = '1' then
                acc_index <= acc_index + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- DUT: arbiter (clk32)
    --------------------------------------------------------------------
    arb : entity work.cpu_arb_model
        generic map (
            G_ALT_SLOTS       => G_ALT_SLOTS,
            G_HIT_MODE        => G_HIT_MODE,
            G_BUSY_FROM_READY => G_BUSY_FROM_READY,
            G_SLOT3           => G_SLOT3
        )
        port map (
            clk32            => clk32,
            reset            => reset,
            cpu_addr         => cpu_addr,
            scpu_fast        => scpu_fast,
            sdram_ready      => sdram_ready,
            sdram_data_valid => sdram_data_valid,
            ctrl_hit_in      => ctrl_hit_in,
            cpu_cyc          => cpu_cyc,
            access_done      => access_done,
            pred_hit_out     => pred_hit
        );

    --------------------------------------------------------------------
    -- SDRAM model (clk64). ce = cpu_cyc crosses clk32->clk64 naturally.
    --------------------------------------------------------------------
    sdram : entity work.sdram_pm_lite
        port map (
            clk        => clk64,
            reset      => reset,
            addr       => cpu_addr,
            we         => '0',
            ce         => cpu_cyc,
            refresh    => refresh,
            fast_path  => sdram_fast_path,
            ready      => sdram_ready,
            data_valid => sdram_data_valid,
            dbg_hit_path => dbg_hit_path,
            cmd_active_pulse    => cmd_active_pulse,
            cmd_active_bank     => cmd_active_bank,
            cmd_active_row      => cmd_active_row,
            cmd_precharge_pulse => cmd_precharge_pulse,
            cmd_precharge_all   => cmd_precharge_all,
            cmd_precharge_bank  => cmd_precharge_bank,
            cmd_refresh_pulse   => cmd_refresh_pulse
        );

    --------------------------------------------------------------------
    -- Mode-2 single-tracker: a shadow of the controller's open row,
    -- slaved to its emitted SDRAM command stream (not an independent
    -- predictor). ctrl_hit_in is combinational against the shadow.
    --------------------------------------------------------------------
    ctrl_hit_in <= '1' when scpu_fast = '1' and shadow_valid = '1'
                        and cpu_addr(22 downto 21) = shadow_bank
                        and cpu_addr(20 downto 8)  = shadow_row
                   else '0';

    -- async refresh generator (clk64). Fires a 1-clk64 pulse every
    -- G_REFRESH_PERIOD cycles, NOT aligned to the arbiter's VIC0 clear.
    refresh_gen : process(clk64)
    begin
        if rising_edge(clk64) then
            if reset = '1' or G_REFRESH_PERIOD = 0 then
                refresh     <= '0';
                refresh_cnt <= 0;
            elsif refresh_cnt >= G_REFRESH_PERIOD - 1 then
                refresh     <= '1';
                refresh_cnt <= 0;
            else
                refresh     <= '0';
                refresh_cnt <= refresh_cnt + 1;
            end if;
        end if;
    end process;

    shadow_proc : process(clk64)
    begin
        if rising_edge(clk64) then
            if reset = '1' then
                shadow_valid <= '0';
            else
                if cmd_precharge_pulse = '1' then
                    shadow_valid <= '0';
                end if;
                if cmd_refresh_pulse = '1' then
                    shadow_valid <= '0';
                end if;
                if cmd_active_pulse = '1' then
                    shadow_bank  <= cmd_active_bank;
                    shadow_row   <= cmd_active_row;
                    shadow_valid <= '1';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Correctness monitor (clk64): real_valid set on data_valid rise,
    -- cleared on each new ce (cpu_cyc) edge. A new ce while the prior
    -- access never reached real_valid = STALE READ (dout_r overwritten
    -- before the previous read completed).
    --------------------------------------------------------------------
    mon_proc : process(clk64)
    begin
        if rising_edge(clk64) then
            if reset = '1' then
                last_cpu_cyc <= '0';
            else
                last_cpu_cyc <= cpu_cyc;
                -- new ce edge while controller not ready -> dropped access.
                if cpu_cyc = '1' and last_cpu_cyc = '0' and sdram_ready = '0' then
                    stale_count <= stale_count + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Throughput counter (clk32): count cpu_cyc fires + HITs.
    --------------------------------------------------------------------
    count_proc : process(clk32)
        variable last_cc : std_logic := '0';
    begin
        if rising_edge(clk32) then
            if reset = '0' then
                if cpu_cyc = '1' and last_cc = '0' then
                    cyc_count <= cyc_count + 1;
                    if pred_hit = '1' then
                        hit_count <= hit_count + 1;
                    end if;
                end if;
            end if;
            last_cc := cpu_cyc;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Stimulus / measurement window + report.
    --------------------------------------------------------------------
    stim : process
        variable l : line;
        variable mhz_x100 : natural;
    begin
        reset <= '1';
        wait for 40 * CLK64_HALF;
        reset <= '0';

        -- measure over G_US microseconds. 1 us = 1000 ns = 128 * CLK64_HALF.
        wait for (G_US * 128) * CLK64_HALF;

        sim_done <= true;

        -- effective MHz = accesses / microseconds, x100 for 2 decimals
        mhz_x100 := (cyc_count * 100) / G_US;

        write(l, string'("==> turbo_throughput_tb")); writeline(output, l);
        write(l, string'("    G_ALT_SLOTS="));       write(l, G_ALT_SLOTS);
        write(l, string'("  G_SLOT3="));             write(l, G_SLOT3);
        write(l, string'("  G_HIT_MODE="));          write(l, G_HIT_MODE);
        write(l, string'("  G_BUSY_FROM_READY="));   write(l, G_BUSY_FROM_READY);
        write(l, string'("  G_STRIDE="));            write(l, G_STRIDE);
        writeline(output, l);
        write(l, string'("    measured_us="));       write(l, G_US);
        write(l, string'("  cpu_accesses="));        write(l, cyc_count);
        write(l, string'("  predicted_hits="));      write(l, hit_count);
        writeline(output, l);
        write(l, string'("    EFFECTIVE_MHZ="));
        write(l, mhz_x100 / 100);
        write(l, string'("."));
        write(l, (mhz_x100 mod 100));
        writeline(output, l);
        write(l, string'("    STALE_READS="));       write(l, stale_count);
        writeline(output, l);
        if stale_count = 0 then
            write(l, string'("    CORRECTNESS=PASS"));
        else
            write(l, string'("    CORRECTNESS=FAIL (stale reads detected)"));
        end if;
        writeline(output, l);

        wait for 4 * CLK64_HALF;
        wait;
    end process;

end architecture;
