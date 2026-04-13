-- cpu_65c816_lda_long_tb.vhd
--
-- Wrapper-level companion to p65c816_lda_long_tb.vhd. Same four scenarios,
-- same memory image, same trace format — but the DUT is cpu_65c816 (the
-- C64 wrapper around P65C816, with 6510 I/O port at $0000-$0001 and the
-- localDi <= localDo when localWe = '0' loopback). Compare against the
-- bare-core trace to find any wrapper-induced misbehavior.
--
-- Wrapper differences vs the bare-core bench:
--   * reset is active-HIGH (not RST_N)
--   * enable is the gated CE
--   * addr is split into addr (16) + addr_hi (8)
--   * we is active-HIGH (the wrapper inverts P65C816.WE internally)
--   * di / do are unsigned, not std_logic_vector
--   * dbg_* outputs are unsigned

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity cpu_65c816_lda_long_tb is
end entity;

architecture sim of cpu_65c816_lda_long_tb is

    -- Clock / reset
    signal clk    : std_logic := '0';
    signal reset  : std_logic := '1';     -- active HIGH on the wrapper
    signal enable : std_logic := '1';

    -- DUT bus
    signal di       : unsigned(7 downto 0) := (others => '0');
    signal do_s     : unsigned(7 downto 0);
    signal addr_s   : unsigned(15 downto 0);
    signal addr_hi  : unsigned(7 downto 0);
    signal we_s     : std_logic;          -- active HIGH on the wrapper
    signal vpa      : std_logic;
    signal vda      : std_logic;
    signal emu_mode : std_logic;
    signal nmi_ack  : std_logic;

    -- 6510 I/O port (the wrapper traps $0000-$0001). Tied off — our test
    -- program never touches them.
    signal diIO : unsigned(7 downto 0) := x"FF";
    signal doIO : unsigned(7 downto 0);

    -- Wrapper debug outputs
    signal dbg_pc    : unsigned(15 downto 0);
    signal dbg_sp    : unsigned(15 downto 0);
    signal dbg_p     : unsigned(7 downto 0);
    signal dbg_ir    : unsigned(7 downto 0);
    signal dbg_pbr   : unsigned(7 downto 0);
    signal dbg_dbr   : unsigned(7 downto 0);
    signal dbg_state : unsigned(3 downto 0);

    -- 64KB bank-$00 memory image (same contents as the bare-core bench)
    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    function init_mem return mem_t is
        variable m : mem_t := (others => x"EA");
    begin
        m(16#FFFC#) := x"00"; m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";
        m(16#FFE6#) := x"00"; m(16#FFE7#) := x"FF";
        m(16#FFEE#) := x"00"; m(16#FFEF#) := x"FF";
        m(16#FFEA#) := x"00"; m(16#FFEB#) := x"FF";
        m(16#FF00#) := x"40";
        m(16#0800#) := x"AF";
        m(16#0801#) := x"20";
        m(16#0802#) := x"D0";
        m(16#0803#) := x"00";
        m(16#0804#) := x"EA";
        m(16#0805#) := x"EA";
        m(16#0806#) := x"EA";
        m(16#0807#) := x"EA";
        m(16#D020#) := x"5A";
        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;

    signal cycle_count : integer := 0;

    -- Scenario control (same enum as the bare-core bench)
    type scenario_t is (SC_BASELINE, SC_DROP_S3, SC_DROP_S4, SC_CORRUPT_AB);
    signal scenario      : scenario_t := SC_BASELINE;
    signal drop_done     : std_logic := '0';
    signal target_state  : std_logic_vector(3 downto 0) := "0011";

    signal corrupt_done   : std_logic := '0';
    signal corrupt_active : std_logic;
    constant CORRUPT_VALUE : std_logic_vector(7 downto 0) := x"FF";

begin

    -- DUT: the wrapper, not the bare core
    dut: entity work.cpu_65c816
        port map (
            clk            => clk,
            enable         => enable,
            reset          => reset,
            nmi_n          => '1',
            nmi_ack        => nmi_ack,
            irq_n          => '1',
            rdy            => '1',
            di             => di,
            do             => do_s,
            addr           => addr_s,
            we             => we_s,
            diIO           => diIO,
            doIO           => doIO,
            addr_hi        => addr_hi,
            emulation_mode => emu_mode,
            vpa            => vpa,
            vda            => vda,
            dbg_pc         => dbg_pc,
            dbg_sp         => dbg_sp,
            dbg_p          => dbg_p,
            dbg_ir         => dbg_ir,
            dbg_pbr        => dbg_pbr,
            dbg_dbr        => dbg_dbr,
            dbg_state      => dbg_state
        );

    -- D_IN corruption gate (wrapper-side)
    corrupt_active <= '1' when scenario = SC_CORRUPT_AB
                              and corrupt_done = '0'
                              and dbg_ir = x"AF"
                              and std_logic_vector(dbg_state) = "0011" else '0';

    -- Combinational ROM read on bank-$00 only.
    -- Note: we drive `di` (unsigned) into the wrapper. The wrapper's
    -- localDi mux only forwards `di` to the CPU when localWe='1' (read)
    -- AND accessIO='0' — both true throughout the $AF execution since
    -- $0800-$0807 and $D020 are all outside $0000-$0001.
    di <= unsigned(CORRUPT_VALUE) when corrupt_active = '1'
          else unsigned(mem(to_integer(addr_s)));

    -- Synchronous write port: wrapper's `we` is active HIGH.
    process(clk)
    begin
        if rising_edge(clk) then
            if enable = '1' and we_s = '1' then
                mem(to_integer(addr_s)) <= std_logic_vector(do_s);
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

    -- Per-clock trace logger. Format mirrors the bare-core bench so the
    -- two logs can be diffed line-by-line. Adds a [W] prefix on the scenario
    -- name to mark "wrapper bench" output unambiguously.
    trace_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' and enable = '1' then
                report
                    "cyc=" & integer'image(cycle_count) &
                    " sc=W:" & scenario_t'image(scenario) &
                    " STATE=" & integer'image(to_integer(dbg_state)) &
                    " IR=$" & to_hstring(dbg_ir) &
                    " PBR=$" & to_hstring(dbg_pbr) &
                    " PC=$" & to_hstring(dbg_pc) &
                    " A_OUT=$" & to_hstring(addr_hi) & to_hstring(addr_s) &
                    " D_IN=$" & to_hstring(di) &
                    " WE=" & std_logic'image(we_s)(2) &
                    " VPA=" & std_logic'image(vpa)(2) &
                    " VDA=" & std_logic'image(vda)(2);
            end if;
        end if;
    end process;

    -- Enable generation: scenario-controlled. Same logic as the bare-core
    -- bench, but the signal name is `enable` instead of `ce`, and the drop
    -- scenarios pull `enable` low for one CLK period.
    enable_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                enable    <= '1';
                drop_done <= '0';
            else
                enable <= '1';
                if (scenario = SC_DROP_S3 or scenario = SC_DROP_S4)
                   and drop_done = '0'
                   and dbg_ir = x"AF"
                   and std_logic_vector(dbg_state) = target_state then
                    enable    <= '0';
                    drop_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Corruption one-shot latch
    corrupt_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                corrupt_done <= '0';
            elsif corrupt_active = '1' then
                corrupt_done <= '1';
            end if;
        end if;
    end process;

    -- Top-level scenario sequencer
    main_proc: process

        procedure wait_for_af is
            variable safety : integer := 0;
        begin
            while not (dbg_ir = x"AF") loop
                wait until rising_edge(clk);
                safety := safety + 1;
                if safety > 5000 then
                    report "wait_for_af: timed out before $AF was fetched"
                        severity failure;
                end if;
            end loop;
        end procedure;

        procedure run_one(sc : scenario_t; tgt : std_logic_vector(3 downto 0)) is
        begin
            report "================ START W:" & scenario_t'image(sc) & " ================";
            scenario     <= sc;
            target_state <= tgt;
            drop_done    <= '0';
            -- Active-HIGH reset on the wrapper
            reset <= '1';
            wait for CLK_PERIOD * 8;
            reset <= '0';
            wait_for_af;
            report "---- W:$AF fetched, observing 80 us ----";
            wait for 80 us;
            report "================ END   W:" & scenario_t'image(sc) & " ================";
        end procedure;

    begin
        reset <= '1';
        wait for CLK_PERIOD * 4;

        run_one(SC_BASELINE,   "0000");
        run_one(SC_DROP_S3,    "0011");
        run_one(SC_DROP_S4,    "0100");
        run_one(SC_CORRUPT_AB, "0011");

        report "=== ALL WRAPPER SCENARIOS COMPLETE ===";
        std.env.finish;
    end process;

end architecture;
