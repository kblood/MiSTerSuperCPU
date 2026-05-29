-- cpu_arb_model.vhd
--
-- Faithful clk32 CPU-slot arbiter, extracted near-verbatim from
-- fpga64_sid_iec.vhd (the cpu_cyc / sdram_busy / busy_cnt / alt_fire / ready-
-- sync block, lines ~3189-3393). Purpose: a standalone, fast-to-simulate
-- model so the speed design space (alt-slots, page-mode HIT, single vs dual
-- row tracker) can be explored *measured*, not assumed, and so the stale-read
-- hazard that wedged HW (Doom BRK $00:000A) is caught in sim before any build.
--
-- The default generic settings reproduce TODAY's RTL behaviour exactly:
--   G_ALT_SLOTS=false, G_HIT_MODE=0 (hit_pred forced '0', busy=011 always).
-- A throughput run with the defaults MUST report ~4 MHz — that validates the
-- model against the known silicon baseline before any experiment is trusted.
--
-- Knobs (generics):
--   G_ALT_SLOTS : enable the Step-5 alt-slot fires at CPU2/6/A/E (via the
--                 registered alt_fire_r / alt_fire_r2, exactly as the
--                 commented-out RTL block intended).
--   G_HIT_MODE  : 0 = forced MISS budget (busy_cnt=011), today's safe default.
--                 1 = arbiter-PRIVATE row predictor (the dual-tracker design
--                     that can drift from the controller -> stale reads).
--                 2 = controller-SOURCED HIT (single tracker): the arbiter
--                     trusts the SDRAM model's own hit decision (ctrl_hit_in),
--                     so prediction can never disagree with reality.
--   G_BUSY_FROM_READY : when true, busy clears on the 2-FF-synced real
--                 data_valid edge instead of the static counter (correct but
--                 ~2 clk32 late). Lets us measure the "true handshake" option.
--
-- Single clk32 domain. The SDRAM model lives in clk64; ce crosses naturally
-- (clk64 is 2x, phase-aligned) and ready/data_valid are brought back through
-- the real 2-FF sync modelled here.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_arb_model is
    generic (
        G_ALT_SLOTS       : boolean := false;
        G_HIT_MODE        : integer := 0;
        G_BUSY_FROM_READY : boolean := false
    );
    port (
        clk32        : in  std_logic;
        reset        : in  std_logic;

        -- CPU request side (the CPU always wants a RAM access in this model;
        -- cs_ram is held '1', no I/O, no DMA, native turbo turbo_m="111").
        cpu_addr     : in  unsigned(24 downto 0);  -- 25-bit phys addr of pending access
        scpu_fast    : in  std_logic;              -- '1' = SuperRAM bank (alt-slot eligible)

        -- SDRAM side (clk64-domain signals, sampled here)
        sdram_ready      : in  std_logic;
        sdram_data_valid : in  std_logic;
        ctrl_hit_in      : in  std_logic;          -- controller's own HIT decision (G_HIT_MODE=2)

        -- Outputs
        cpu_cyc      : out std_logic;              -- 1 clk32 pulse: launch SDRAM access now
        access_done  : out std_logic;              -- 1 clk32 pulse: arbiter considers prior access complete
        pred_hit_out : out std_logic               -- the HIT decision the arbiter acted on (for monitor)
    );
end entity;

architecture sim of cpu_arb_model is

    -- 32-slot wheel (sysCycleDef). CPU slots 16..31.
    constant CYCLE_VIC0 : integer := 12;
    constant CYCLE_CPU0 : integer := 16;
    constant CYCLE_CPU1 : integer := 17;
    constant CYCLE_CPU2 : integer := 18;
    constant CYCLE_CPU4 : integer := 20;
    constant CYCLE_CPU5 : integer := 21;
    constant CYCLE_CPU6 : integer := 22;
    constant CYCLE_CPU8 : integer := 24;
    constant CYCLE_CPU9 : integer := 25;
    constant CYCLE_CPUA : integer := 26;
    constant CYCLE_CPUC : integer := 28;
    constant CYCLE_CPUD : integer := 29;
    constant CYCLE_CPUE : integer := 30;

    signal sysCycle : integer range 0 to 31 := 0;

    signal sdram_busy_cnt : unsigned(2 downto 0) := (others => '0');
    signal sdram_busy     : std_logic := '0';
    signal sdram_hit_pred : std_logic := '0';

    -- 2-FF ready sync (clk64->clk32) and rising-edge detect, as in RTL.
    signal sdram_ready_sync      : std_logic_vector(1 downto 0) := (others => '0');
    signal sdram_ready_sync_prev : std_logic := '0';
    signal sdram_dv_sync         : std_logic_vector(1 downto 0) := (others => '0');

    -- Arbiter-private row predictor (G_HIT_MODE=1).
    signal sdram_pred_bank  : unsigned(1 downto 0)  := (others => '0');
    signal sdram_pred_row   : unsigned(12 downto 0) := (others => '0');
    signal sdram_pred_valid : std_logic := '0';

    -- alt-slot registered fire decisions.
    signal alt_fire_r  : std_logic := '0';
    signal alt_fire_r2 : std_logic := '0';

    signal cpu_cyc_i   : std_logic;
    signal turbo_m     : std_logic_vector(2 downto 0) := "111";  -- native max turbo
    constant cs_ram          : std_logic := '1';
    constant io_enable       : std_logic := '1';
    constant scpu_force_1mhz : std_logic := '0';

    -- combinational predictor compare (mirrors RTL §3201)
    signal pred_hit_comb : std_logic;

begin

    sdram_busy <= '1' when sdram_busy_cnt /= "000" else '0';

    -- HIT predictor source select.
    --   mode 0: forced '0' (today's RTL).
    --   mode 1: private predictor compare.
    --   mode 2: controller-sourced hit (single tracker, can't drift).
    gen_hit0 : if G_HIT_MODE = 0 generate
        sdram_hit_pred <= '0';
        pred_hit_comb  <= '0';
    end generate;
    gen_hit1 : if G_HIT_MODE = 1 generate
        pred_hit_comb <= '1' when sdram_pred_valid = '1'
                              and cpu_addr(22 downto 21) = sdram_pred_bank
                              and cpu_addr(20 downto 8)  = sdram_pred_row
                         else '0';
        sdram_hit_pred <= pred_hit_comb;
    end generate;
    gen_hit2 : if G_HIT_MODE = 2 generate
        pred_hit_comb  <= ctrl_hit_in;
        sdram_hit_pred <= ctrl_hit_in;
    end generate;

    -- cpu_cyc: main slots (CPU0/4/8/C) + optional alt slots, mirrors RTL §3296.
    cpu_cyc_i <= '1' when (sdram_busy = '0' and (
                    (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' and scpu_force_1mhz = '0') or
                    (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and cs_ram = '1' and scpu_force_1mhz = '0') or
                    (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and cs_ram = '1' and scpu_force_1mhz = '0') or
                    (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1'))
                )) or (alt_fire_r = '1' and scpu_force_1mhz = '0')
                   or (alt_fire_r2 = '1' and scpu_force_1mhz = '0') else '0';

    cpu_cyc      <= cpu_cyc_i;
    pred_hit_out <= sdram_hit_pred;

    process(clk32)
        variable launch : boolean;
    begin
        if rising_edge(clk32) then
            if reset = '1' then
                sysCycle              <= 0;
                sdram_busy_cnt        <= (others => '0');
                sdram_ready_sync      <= (others => '0');
                sdram_ready_sync_prev <= '0';
                sdram_dv_sync         <= (others => '0');
                sdram_pred_valid      <= '0';
                alt_fire_r            <= '0';
                alt_fire_r2           <= '0';
                access_done           <= '0';
            else
                -- wheel
                if sysCycle = 31 then
                    sysCycle <= 0;
                else
                    sysCycle <= sysCycle + 1;
                end if;

                -- syncs
                sdram_ready_sync      <= sdram_ready_sync(0) & sdram_ready;
                sdram_ready_sync_prev <= sdram_ready_sync(1);
                sdram_dv_sync         <= sdram_dv_sync(0) & sdram_data_valid;

                access_done <= '0';

                -- busy counter (mirrors RTL §3344). On a cpu_cyc fire that
                -- drives an SDRAM access, preload the predicted budget; else
                -- count down, with the synced-ready early-clear.
                if cpu_cyc_i = '1' and cs_ram = '1' then
                    if G_BUSY_FROM_READY then
                        -- True-handshake mode: load a large floor; only the
                        -- synced data_valid edge below clears it.
                        sdram_busy_cnt <= "111";
                    elsif sdram_hit_pred = '1' then
                        sdram_busy_cnt <= "001";   -- HIT — short reservation
                    else
                        sdram_busy_cnt <= "011";   -- MISS — worst-case floor
                    end if;

                    -- update private predictor row (G_HIT_MODE=1 only)
                    if G_HIT_MODE = 1 then
                        sdram_pred_bank  <= cpu_addr(22 downto 21);
                        sdram_pred_row   <= cpu_addr(20 downto 8);
                        sdram_pred_valid <= '1';
                    end if;
                elsif sdram_busy_cnt /= "000" then
                    if G_BUSY_FROM_READY then
                        if sdram_dv_sync(1) = '1' then
                            sdram_busy_cnt <= "000";
                        end if;
                    else
                        if sdram_ready_sync(1) = '1' and sdram_ready_sync_prev = '0' then
                            sdram_busy_cnt <= "000";
                        else
                            sdram_busy_cnt <= sdram_busy_cnt - 1;
                        end if;
                    end if;
                end if;

                -- access_done pulses the clk32 the busy counter reaches 0
                -- after having been non-zero (the arbiter now believes the
                -- data of the in-flight access is available).
                if sdram_busy_cnt = "001" and not (cpu_cyc_i = '1' and cs_ram = '1') then
                    if G_BUSY_FROM_READY then
                        if sdram_dv_sync(1) = '1' then
                            access_done <= '1';
                        end if;
                    else
                        access_done <= '1';
                    end if;
                end if;

                -- refresh invalidates the private predictor row (RTL §3376).
                if sysCycle = CYCLE_VIC0 then
                    sdram_pred_valid <= '0';
                end if;

                -- alt-slot fire latch (RTL Step 5 block, §3380). Latch the
                -- decision one slot ahead (CPU1/5/9/D) so cpu_cyc sees a clean
                -- registered output, then a second stage (alt_fire_r2) for the
                -- +1 slot. Only on the SuperRAM fast path, only if not busy.
                if G_ALT_SLOTS then
                    -- Latch the alt-slot fire one slot ahead (CPU1/5/9/D) for
                    -- the alt slot at CPU2/6/A/E. SAFE only when the SDRAM will
                    -- be free by then: busy_cnt<=1 means it clears on THIS edge,
                    -- so the +1 alt slot sees the controller idle. On a MISS
                    -- (busy_cnt=011) the condition is false -> no alt fire ->
                    -- no premature ce. This is the correctness gate.
                    if (sysCycle = CYCLE_CPU1 or sysCycle = CYCLE_CPU5
                        or sysCycle = CYCLE_CPU9 or sysCycle = CYCLE_CPUD)
                       and scpu_fast = '1'
                       and sdram_busy_cnt <= to_unsigned(1, 3) then
                        alt_fire_r <= '1';
                    else
                        alt_fire_r <= '0';
                    end if;
                    alt_fire_r2 <= '0';  -- second alt stage disabled for now (single alt slot)
                else
                    alt_fire_r  <= '0';
                    alt_fire_r2 <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture;
