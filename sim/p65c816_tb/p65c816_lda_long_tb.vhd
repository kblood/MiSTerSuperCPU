-- p65c816_lda_long_tb.vhd
--
-- Testbench for the bare P65C816 core (no fpga64_sid_iec wrapper).
-- Investigates the LDA-long ($AF) crash by running the same opcode
-- under three different CE-pulse patterns and recording every
-- enable-active cycle's STATE / IR / PC / A_OUT / D_IN / VPA / VDA.
--
-- Scenarios:
--   1. SCENARIO_BASELINE   - CE='1' every clock (ground truth)
--   2. SCENARIO_DROP_S3    - one CE pulse dropped while STATE=3 of $AF
--   3. SCENARIO_DROP_S4    - one CE pulse dropped while STATE=4 of $AF
--
-- Pass criteria (testbench correctness, NOT bug-reproduction):
--   - Baseline: $AF executes in exactly 5 enable cycles, A_OUT=$00D020
--     during the data fetch, D_IN=$5A on that fetch, PC reaches $0804.
--   - All three scenarios run to completion without GHDL errors.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_lda_long_tb is
end entity;

architecture sim of p65c816_lda_long_tb is

    -- Clock / reset
    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    signal ce     : std_logic := '1';

    -- DUT bus
    signal d_in   : std_logic_vector(7 downto 0) := (others => '0');
    signal d_out  : std_logic_vector(7 downto 0);
    signal a_out  : std_logic_vector(23 downto 0);
    signal we_n   : std_logic;             -- P65C816.WE is active-low (read='1', write='0')
    signal vpa    : std_logic;
    signal vda    : std_logic;
    signal mlb_s  : std_logic;
    signal vpb_s  : std_logic;
    signal ef_out : std_logic;
    signal rdy_out: std_logic;

    -- DUT debug
    signal dbg_pc    : std_logic_vector(15 downto 0);
    signal dbg_sp    : std_logic_vector(15 downto 0);
    signal dbg_p     : std_logic_vector(7 downto 0);
    signal dbg_ir    : std_logic_vector(7 downto 0);
    signal dbg_pbr   : std_logic_vector(7 downto 0);
    signal dbg_dbr   : std_logic_vector(7 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    -- 64KB bank-$00 memory model (sufficient for the test program)
    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    -- Initialize the memory image. Anything not explicitly set is $EA (NOP),
    -- so a stray fetch in the wrong place is harmless rather than catastrophic.
    function init_mem return mem_t is
        variable m : mem_t := (others => x"EA");
    begin
        -- Reset vector -> $0800
        m(16#FFFC#) := x"00";
        m(16#FFFD#) := x"08";
        -- IRQ/BRK vector (emulation mode) -> $FF00 (parked RTI)
        m(16#FFFE#) := x"00";
        m(16#FFFF#) := x"FF";
        -- Native mode vectors -> also $FF00
        m(16#FFE6#) := x"00"; m(16#FFE7#) := x"FF"; -- BRK
        m(16#FFEE#) := x"00"; m(16#FFEF#) := x"FF"; -- IRQ
        m(16#FFEA#) := x"00"; m(16#FFEB#) := x"FF"; -- NMI
        m(16#FF00#) := x"40";  -- RTI
        -- Test program at $0800
        m(16#0800#) := x"AF";  -- LDA long
        m(16#0801#) := x"20";  -- AAL
        m(16#0802#) := x"D0";  -- AAH
        m(16#0803#) := x"00";  -- AB (bank operand)
        m(16#0804#) := x"EA";  -- where PC SHOULD land after $AF
        m(16#0805#) := x"EA";
        m(16#0806#) := x"EA";
        m(16#0807#) := x"EA";
        -- Data target
        m(16#D020#) := x"5A";  -- distinctive value
        return m;
    end function;

    signal mem : mem_t := init_mem;

    -- Clock period: 32 MHz, matching the existing reu_sdram_tb (31.25 ns).
    constant CLK_PERIOD : time := 31250 ps;

    -- Cycle counter (counts every CLK rising edge regardless of CE)
    signal cycle_count : integer := 0;

    -- Scenario control
    type scenario_t is (SC_BASELINE, SC_DROP_S3, SC_DROP_S4,
                        SC_CORRUPT_AB, SC_CORRUPT_S3_MULTI, SC_CORRUPT_S0_NEXT,
                        SC_BASELINE_AD);
    signal scenario      : scenario_t := SC_BASELINE;
    signal drop_armed    : std_logic := '0';   -- '1' = waiting for the target STATE
    signal drop_done     : std_logic := '0';   -- '1' once we've dropped one pulse
    signal target_state  : std_logic_vector(3 downto 0) := "0011";

    -- D_IN corruption injector. Several scenarios use this in different ways:
    --   SC_CORRUPT_AB        : one cycle of $FF while IR=$AF AND STATE=3
    --   SC_CORRUPT_S3_MULTI  : sustained $FF as long as IR=$AF AND STATE=3
    --                          (in practice STATE=3 only lasts one CE-active
    --                          cycle, but the override is held longer via a
    --                          countdown — see corrupt_hold_proc below)
    --   SC_CORRUPT_S0_NEXT   : one cycle of $00 while IR=$AF AND STATE=0 AND PC=$0804
    --                          (the post-$AF opcode fetch position)
    signal corrupt_done   : std_logic := '0';   -- latched after one corruption fires
    signal corrupt_active : std_logic;          -- combinational override gate
    signal corrupt_value  : std_logic_vector(7 downto 0) := x"FF";
    -- For SC_CORRUPT_S3_MULTI: a countdown that holds the override for N
    -- additional clk32 edges past the initial trigger.
    signal corrupt_hold   : integer range 0 to 16 := 0;

begin

    -- DUT
    dut: entity work.P65C816
        port map (
            CLK       => clk,
            RST_N     => rst_n,
            CE        => ce,
            RDY_IN    => '1',
            NMI_N     => '1',
            IRQ_N     => '1',
            ABORT_N   => '1',
            D_IN      => d_in,
            D_OUT     => d_out,
            A_OUT     => a_out,
            WE        => we_n,
            RDY_OUT   => rdy_out,
            VPA       => vpa,
            VDA       => vda,
            MLB       => mlb_s,
            VPB       => vpb_s,
            EF_OUT    => ef_out,
            DBG_PC    => dbg_pc,
            DBG_SP    => dbg_sp,
            DBG_P     => dbg_p,
            DBG_IR    => dbg_ir,
            DBG_PBR   => dbg_pbr,
            DBG_DBR   => dbg_dbr,
            DBG_STATE => dbg_state
        );

    -- D_IN corruption gate. Several scenarios contribute:
    --
    -- SC_CORRUPT_AB: one cycle, while IR=$AF AND STATE=3. corrupt_done
    --                latches after firing so it doesn't repeat.
    --
    -- SC_CORRUPT_S3_MULTI: same trigger condition (IR=$AF AND STATE=3),
    --                but we ALSO assert the override while corrupt_hold > 0,
    --                so the override is held for several CE-active cycles
    --                past the initial trigger. corrupt_hold counts down in
    --                corrupt_hold_proc.
    --
    -- SC_CORRUPT_S0_NEXT: one cycle, while IR=$AF AND STATE=0 AND PC=$0804.
    --                That is the rising edge where the CPU samples the next
    --                opcode after $AF — corrupting it forces a fake "next
    --                instruction." Value is $00 (BRK) instead of $FF.
    corrupt_active <= '1' when (scenario = SC_CORRUPT_AB
                                and corrupt_done = '0'
                                and dbg_ir = x"AF"
                                and dbg_state = "0011")
                          else '1' when (scenario = SC_CORRUPT_S3_MULTI
                                         and (
                                              (corrupt_done = '0'
                                               and dbg_ir = x"AF"
                                               and dbg_state = "0011")
                                              or corrupt_hold > 0
                                             ))
                          else '1' when (scenario = SC_CORRUPT_S0_NEXT
                                         and corrupt_done = '0'
                                         and dbg_ir = x"AF"
                                         and dbg_state = "0000"
                                         and dbg_pc = x"0804")
                          else '0';

    -- Pick the corruption value based on scenario.
    corrupt_value <= x"00" when scenario = SC_CORRUPT_S0_NEXT else x"FF";

    -- Combinational ROM/RAM read on bank-$00 only, with optional override.
    -- High bank bits ignored: the test program lives entirely in bank $00.
    --
    -- For SC_BASELINE_AD: overlay a 3-byte $AD $20 $D0 program at $0800,
    -- with $EA at $0803 (where PC should land after $AD finishes). The
    -- VIC target $D020 is already $5A in the baseline mem image. This
    -- lets us trace the structurally-similar $AD LDA abs without writing
    -- a separate test program or recompiling memory.
    d_in <= corrupt_value when corrupt_active = '1'
            else x"AD" when (scenario = SC_BASELINE_AD and a_out(15 downto 0) = x"0800")
            else x"20" when (scenario = SC_BASELINE_AD and a_out(15 downto 0) = x"0801")
            else x"D0" when (scenario = SC_BASELINE_AD and a_out(15 downto 0) = x"0802")
            else x"EA" when (scenario = SC_BASELINE_AD and a_out(15 downto 0) = x"0803")
            else mem(to_integer(unsigned(a_out(15 downto 0))));

    -- Synchronous write port: P65C816 WE is active-low (we_n='0' = write).
    -- Latched on the rising edge when CE is high (the same edge that the
    -- DUT itself uses to commit register state).
    process(clk)
    begin
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                mem(to_integer(unsigned(a_out(15 downto 0)))) <= d_out;
            end if;
        end if;
    end process;

    -- Free-running clock
    clock_proc: process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- Cycle counter
    cycle_proc: process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    -- Per-clock trace logger: emits one report line per rising edge while
    -- CE='1' AND the DUT is past reset (dbg_ir not all-X). Reports show the
    -- state THE DUT IS ABOUT TO LEAVE on this edge (i.e. the values that
    -- drove ADDR_BUS, D_IN, etc. during this clock).
    trace_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '1' and ce = '1' then
                report
                    "cyc=" & integer'image(cycle_count) &
                    " sc=" & scenario_t'image(scenario) &
                    " STATE=" & integer'image(to_integer(unsigned(dbg_state))) &
                    " IR=$" & to_hstring(dbg_ir) &
                    " PBR=$" & to_hstring(dbg_pbr) &
                    " PC=$" & to_hstring(dbg_pc) &
                    " A_OUT=$" & to_hstring(a_out) &
                    " D_IN=$" & to_hstring(d_in) &
                    " WEn=" & std_logic'image(we_n)(2) &
                    " VPA=" & std_logic'image(vpa)(2) &
                    " VDA=" & std_logic'image(vda)(2);
            end if;
        end if;
    end process;

    -- CE generation: scenario-controlled. By default ce='1'. The drop
    -- scenarios pull ce low for exactly one CLK_PERIOD when the DUT
    -- enters its target state inside an $AF instruction. SC_CORRUPT_AB
    -- does NOT drop CE — it leaves CE high and corrupts D_IN instead.
    --
    -- Detection: dbg_ir='AF' AND dbg_state matches AND drop_done='0'.
    -- Once dropped, drop_done latches so we don't drop more than one pulse.
    ce_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ce <= '1';
                drop_done <= '0';
            else
                -- Default: enable
                ce <= '1';
                if (scenario = SC_DROP_S3 or scenario = SC_DROP_S4)
                   and drop_done = '0'
                   and dbg_ir = x"AF"
                   and dbg_state = target_state then
                    -- Pull CE low for the NEXT clock edge by setting it now.
                    -- (ce is registered, so this assignment takes effect at
                    -- the next rising edge — that is the edge we want to
                    -- silence.)
                    ce <= '0';
                    drop_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Corruption one-shot latch + multi-cycle hold counter.
    --
    -- For SC_CORRUPT_AB and SC_CORRUPT_S0_NEXT: corrupt_done latches the
    -- moment corrupt_active fires, so the override only fires once.
    --
    -- For SC_CORRUPT_S3_MULTI: when the trigger condition first matches,
    -- we load corrupt_hold with N (number of EXTRA cycles to keep the
    -- override asserted past the initial cycle), and we also set
    -- corrupt_done so the trigger logic doesn't keep re-loading the
    -- counter. corrupt_hold then counts down each clk32 edge, holding
    -- corrupt_active high via the OR-with-corrupt_hold>0 branch.
    corrupt_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                corrupt_done <= '0';
                corrupt_hold <= 0;
            else
                if scenario = SC_CORRUPT_S3_MULTI
                   and corrupt_done = '0'
                   and dbg_ir = x"AF"
                   and dbg_state = "0011" then
                    -- Initial trigger: latch + load 4 extra hold cycles.
                    -- Total override window = 1 (initial) + 4 (held) = 5
                    -- consecutive clk32 edges. The CPU only samples on the
                    -- next CE-active rising edge, so this guarantees the
                    -- corrupted byte is what the CPU clocks in for AB even
                    -- if there's any combinational settling delay.
                    corrupt_done <= '1';
                    corrupt_hold <= 4;
                elsif corrupt_hold > 0 then
                    corrupt_hold <= corrupt_hold - 1;
                elsif corrupt_active = '1' then
                    -- Single-cycle scenarios: latch corrupt_done so the
                    -- override only fires once.
                    corrupt_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Top-level scenario sequencer.
    main_proc: process

        -- Wait until the DUT has finished its reset sequence and is sitting
        -- on the target opcode at $0800. We watch dbg_ir to become the
        -- expected opcode for the first time AFTER reset is released.
        procedure wait_for_opcode(op : std_logic_vector(7 downto 0)) is
            variable safety : integer := 0;
        begin
            while not (dbg_ir = op) loop
                wait until rising_edge(clk);
                safety := safety + 1;
                if safety > 5000 then
                    report "wait_for_opcode: timed out before $"
                        & to_hstring(op) & " was fetched"
                        severity failure;
                end if;
            end loop;
        end procedure;

        -- Run one scenario from cold reset to ~80 us simulated.
        -- `expected_op` selects which opcode to wait for after reset.
        -- All existing scenarios use $AF; SC_BASELINE_AD uses $AD.
        procedure run_one(sc          : scenario_t;
                          tgt         : std_logic_vector(3 downto 0);
                          expected_op : std_logic_vector(7 downto 0)) is
        begin
            report "================ START " & scenario_t'image(sc) & " ================";
            scenario     <= sc;
            target_state <= tgt;
            drop_done    <= '0';
            -- Reset
            rst_n <= '0';
            wait for CLK_PERIOD * 8;
            rst_n <= '1';
            -- Let the DUT fetch through reset and reach the expected opcode
            wait_for_opcode(expected_op);
            report "---- $" & to_hstring(expected_op)
                & " fetched, observing " & integer'image(80) & " us ----";
            wait for 80 us;
            report "================ END   " & scenario_t'image(sc) & " ================";
        end procedure;

    begin
        -- Initial reset
        rst_n <= '0';
        wait for CLK_PERIOD * 4;

        run_one(SC_BASELINE,         "0000", x"AF"); -- target unused in baseline
        run_one(SC_DROP_S3,          "0011", x"AF"); -- drop one CE pulse during state 3
        run_one(SC_DROP_S4,          "0100", x"AF"); -- drop one CE pulse during state 4
        run_one(SC_CORRUPT_AB,       "0011", x"AF"); -- $FF on D_IN for one cycle during state 3
        run_one(SC_CORRUPT_S3_MULTI, "0011", x"AF"); -- $FF held for ~5 cycles starting at state 3
        run_one(SC_CORRUPT_S0_NEXT,  "0000", x"AF"); -- $00 on D_IN at the post-$AF opcode fetch
                                                     -- (PC=$0804, STATE=0, IR still $AF)
        -- Control trace: 3-byte $AD LDA abs $D020, structurally similar to
        -- $AF (PC fetches → I/O data fetch → next opcode), used to compare
        -- cycle-by-cycle against the $AF baseline. Hardware says $AD does
        -- NOT crash; $AF does. Looking for any structural difference in
        -- state count, address bus mode transitions, or VPA/VDA pattern
        -- between the two that the bare-core bench can show without
        -- modeling the system bus.
        run_one(SC_BASELINE_AD,      "0000", x"AD"); -- 3-byte LDA abs to $D020

        report "=== ALL SCENARIOS COMPLETE ===";
        std.env.finish;
    end process;

end architecture;
