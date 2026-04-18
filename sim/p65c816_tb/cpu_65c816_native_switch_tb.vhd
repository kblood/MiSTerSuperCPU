-- cpu_65c816_native_switch_tb.vhd
--
-- Wrapper-level companion to p65c816_native_switch_tb.vhd.
--
-- Runs the same native-switch sequence against cpu_65c816 to determine whether
-- failures are introduced by the wrapper rather than the bare P65C816 core.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity cpu_65c816_native_switch_tb is
end entity;

architecture sim of cpu_65c816_native_switch_tb is

    signal clk    : std_logic := '0';
    signal reset  : std_logic := '1';
    signal enable : std_logic := '1';

    signal di       : unsigned(7 downto 0) := (others => '0');
    signal do_s     : unsigned(7 downto 0);
    signal addr_s   : unsigned(15 downto 0);
    signal addr_hi  : unsigned(7 downto 0);
    signal we_s     : std_logic;
    signal vpa      : std_logic;
    signal vda      : std_logic;
    signal emu_mode : std_logic;
    signal nmi_ack  : std_logic;

    signal diIO : unsigned(7 downto 0) := x"FF";
    signal doIO : unsigned(7 downto 0);

    signal dbg_pc    : unsigned(15 downto 0);
    signal dbg_sp    : unsigned(15 downto 0);
    signal dbg_p     : unsigned(7 downto 0);
    signal dbg_ir    : unsigned(7 downto 0);
    signal dbg_pbr   : unsigned(7 downto 0);
    signal dbg_dbr   : unsigned(7 downto 0);
    signal dbg_state : unsigned(3 downto 0);

    type mem_lo_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type mem_hi_t is array (0 to 1) of std_logic_vector(7 downto 0);

    function init_mem_lo return mem_lo_t is
        variable m : mem_lo_t := (others => x"EA");
    begin
        m(16#FFFC#) := x"00";
        m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FFE6#) := x"00";  m(16#FFE7#) := x"FF";
        m(16#FFEE#) := x"00";  m(16#FFEF#) := x"FF";
        m(16#FFEA#) := x"00";  m(16#FFEB#) := x"FF";
        m(16#FF00#) := x"40";

        m(16#0800#) := x"78"; -- SEI
        m(16#0801#) := x"18"; -- CLC
        m(16#0802#) := x"FB"; -- XCE
        m(16#0803#) := x"C2"; -- REP
        m(16#0804#) := x"30"; -- #$30
        m(16#0805#) := x"A9"; -- LDA #
        m(16#0806#) := x"34"; -- low
        m(16#0807#) := x"12"; -- high
        m(16#0808#) := x"5C"; -- JML
        m(16#0809#) := x"00";
        m(16#080A#) := x"20";
        m(16#080B#) := x"20";
        m(16#080C#) := x"EA";
        return m;
    end function;

    function init_mem_hi return mem_hi_t is
        variable m : mem_hi_t := (others => x"EA");
    begin
        m(0) := x"80";
        m(1) := x"FE";
        return m;
    end function;

    signal mem_lo : mem_lo_t := init_mem_lo;
    signal mem_hi : mem_hi_t := init_mem_hi;
    signal full_addr : unsigned(23 downto 0);
    signal verbose : std_logic := '0';

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    type scenario_t is (SC_BASELINE, SC_DROP_ON_XCE, SC_DROP_AFTER_XCE,
                        SC_DROP_ON_REP_OP, SC_DROP_ON_LDA_OP1);
    signal scenario : scenario_t := SC_BASELINE;
    signal drop_done : std_logic := '0';

    signal saw_xce_fetch  : std_logic := '0';
    signal saw_post_xce   : std_logic := '0';
    signal emu_after_xce  : std_logic := '1';
    signal saw_rep_post   : std_logic := '0';
    signal p_after_rep    : unsigned(7 downto 0) := (others => '0');
    signal saw_jml_fetch  : std_logic := '0';
    signal pbr_at_jml     : unsigned(7 downto 0) := (others => '0');
    signal pc_at_jml      : unsigned(15 downto 0) := (others => '0');
    signal saw_target     : std_logic := '0';
    signal pbr_at_target  : unsigned(7 downto 0) := (others => '0');
    signal pc_at_target   : unsigned(15 downto 0) := (others => '0');

    signal done_xce       : std_logic := '0';
    signal done_rep       : std_logic := '0';
    signal done_jml       : std_logic := '0';

begin

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

    full_addr <= addr_hi & addr_s;

    process(all)
        variable bank : integer;
        variable offs : integer;
    begin
        bank := to_integer(addr_hi);
        offs := to_integer(addr_s);

        if bank = 16#00# then
            di <= unsigned(mem_lo(offs));
        elsif bank = 16#20# and offs >= 16#2000# and offs <= 16#2001# then
            di <= unsigned(mem_hi(offs - 16#2000#));
        else
            di <= x"EA";
        end if;
    end process;

    process(clk)
        variable bank : integer;
        variable offs : integer;
    begin
        if rising_edge(clk) then
            if enable = '1' and we_s = '1' then
                bank := to_integer(addr_hi);
                offs := to_integer(addr_s);
                if bank = 16#00# then
                    mem_lo(offs) <= std_logic_vector(do_s);
                elsif bank = 16#20# and offs >= 16#2000# and offs <= 16#2001# then
                    mem_hi(offs - 16#2000#) <= std_logic_vector(do_s);
                end if;
            end if;
        end if;
    end process;

    clock_proc: process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    cycle_proc: process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    trace_proc: process(clk)
    begin
        if rising_edge(clk) then
            if verbose = '1' and reset = '0' and enable = '1' and cycle_count >= 18 and cycle_count <= 80 then
                report "TRACE W:" & scenario_t'image(scenario) &
                       " cyc=" & integer'image(cycle_count) &
                       " IR=$" & to_hstring(dbg_ir) &
                       " PBR=$" & to_hstring(dbg_pbr) &
                       " PC=$" & to_hstring(dbg_pc) &
                       " P=$" & to_hstring(dbg_p) &
                       " E=" & std_logic'image(emu_mode)(2) &
                       " A=$" & to_hstring(addr_hi) & to_hstring(addr_s) &
                       " DI=$" & to_hstring(di);
            end if;
        end if;
    end process;

    enable_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                enable <= '1';
                drop_done <= '0';
            else
                enable <= '1';
                if drop_done = '0' then
                    if scenario = SC_DROP_ON_XCE
                       and dbg_ir = x"FB" then
                        enable <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_AFTER_XCE
                       and dbg_pc = x"0803" then
                        enable <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_ON_REP_OP
                       and dbg_ir = x"C2" and dbg_pc = x"0804" then
                        enable <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_ON_LDA_OP1
                       and dbg_ir = x"A9" and dbg_pc = x"0806" then
                        enable <= '0';
                        drop_done <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                saw_xce_fetch <= '0';
                saw_post_xce  <= '0';
                saw_rep_post  <= '0';
                saw_jml_fetch <= '0';
                saw_target    <= '0';
                done_xce      <= '0';
                done_rep      <= '0';
                done_jml      <= '0';
            elsif enable = '1' then
                if dbg_ir = x"FB" then
                    saw_xce_fetch <= '1';
                elsif saw_xce_fetch = '1' and done_xce = '0' then
                    saw_post_xce <= '1';
                    emu_after_xce <= emu_mode;
                    done_xce <= '1';
                end if;

                if dbg_ir = x"C2" and dbg_pc = x"0805" and done_rep = '0' then
                    saw_rep_post <= '1';
                    p_after_rep <= dbg_p;
                    done_rep <= '1';
                end if;

                if dbg_ir = x"5C" and done_jml = '0' then
                    saw_jml_fetch <= '1';
                    pbr_at_jml <= dbg_pbr;
                    pc_at_jml  <= dbg_pc;
                end if;

                if dbg_pbr = x"20" and dbg_pc = x"2000" and done_jml = '0' then
                    saw_target <= '1';
                    pbr_at_target <= dbg_pbr;
                    pc_at_target  <= dbg_pc;
                    done_jml <= '1';
                end if;
            end if;
        end if;
    end process;

    main_proc: process
        procedure reset_observers is
        begin
            saw_xce_fetch <= '0';
            saw_post_xce <= '0';
            emu_after_xce <= '1';
            saw_rep_post <= '0';
            p_after_rep <= (others => '0');
            saw_jml_fetch <= '0';
            pbr_at_jml <= (others => '0');
            pc_at_jml <= (others => '0');
            saw_target <= '0';
            pbr_at_target <= (others => '0');
            pc_at_target <= (others => '0');
            drop_done <= '0';
            done_xce <= '0';
            done_rep <= '0';
            done_jml <= '0';
            mem_lo <= init_mem_lo;
            mem_hi <= init_mem_hi;
        end procedure;

        procedure wait_for_completion is
        begin
            wait for 3 us;
        end procedure;

        procedure run_one(sc : scenario_t) is
        begin
            report "START W:" & scenario_t'image(sc);
            scenario <= sc;
            verbose <= '1' when sc = SC_BASELINE else '0';
            reset_observers;
            reset <= '1';
            wait for CLK_PERIOD * 8;
            reset <= '0';
            wait_for_completion;

            verbose <= '0';

            report "RESULT W:" & scenario_t'image(sc) &
                   " final_IR=$" & to_hstring(dbg_ir) &
                   " final_P=$" & to_hstring(dbg_p) &
                   " final_E=" & std_logic'image(emu_mode)(2) &
                   " final_PBR=$" & to_hstring(dbg_pbr) &
                   " final_PC=$" & to_hstring(dbg_pc);
        end procedure;
    begin
        run_one(SC_BASELINE);
        run_one(SC_DROP_ON_XCE);
        run_one(SC_DROP_AFTER_XCE);
        run_one(SC_DROP_ON_REP_OP);
        run_one(SC_DROP_ON_LDA_OP1);
        report "DONE wrapper";
        std.env.finish;
    end process;

end architecture;
