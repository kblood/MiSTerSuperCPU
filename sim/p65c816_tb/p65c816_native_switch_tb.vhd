-- p65c816_native_switch_tb.vhd
--
-- Focused native-mode transition bench for the bare P65C816 core.
--
-- Purpose:
--   1. Verify that CLC/XCE transitions from emulation to native mode.
--   2. Verify that REP #$30 clears M/X.
--   3. Verify that a following 16-bit immediate LDA consumes 3 bytes total.
--   4. Verify that a following JML changes PBR/PC correctly.
--   5. Optionally perturb CE around the critical instructions.
--
-- Program at $0800:
--   0800  78          SEI
--   0801  18          CLC
--   0802  FB          XCE
--   0803  C2 30       REP #$30
--   0805  A9 34 12    LDA #$1234
--   0808  5C 00 20 20 JML $20:2000
--   080C  EA          NOP (must not execute if JML works)
--
-- Target bank program:
--   $20:2000 80 FE    BRA *

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_native_switch_tb is
end entity;

architecture sim of p65c816_native_switch_tb is

    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    signal ce     : std_logic := '1';

    signal d_in   : std_logic_vector(7 downto 0) := (others => '0');
    signal d_out  : std_logic_vector(7 downto 0);
    signal a_out  : std_logic_vector(23 downto 0);
    signal we_n   : std_logic;
    signal vpa    : std_logic;
    signal vda    : std_logic;
    signal mlb_s  : std_logic;
    signal vpb_s  : std_logic;
    signal ef_out : std_logic;
    signal rdy_out: std_logic;

    signal dbg_pc    : std_logic_vector(15 downto 0);
    signal dbg_sp    : std_logic_vector(15 downto 0);
    signal dbg_p     : std_logic_vector(7 downto 0);
    signal dbg_ir    : std_logic_vector(7 downto 0);
    signal dbg_pbr   : std_logic_vector(7 downto 0);
    signal dbg_dbr   : std_logic_vector(7 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    type mem_lo_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type mem_hi_t is array (0 to 1) of std_logic_vector(7 downto 0);

    function init_mem_lo return mem_lo_t is
        variable m : mem_lo_t := (others => x"EA");
    begin
        -- reset -> $0800
        m(16#FFFC#) := x"00";
        m(16#FFFD#) := x"08";

        -- IRQ/BRK vectors -> $FF00 parked RTI
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FFE6#) := x"00";  m(16#FFE7#) := x"FF";
        m(16#FFEE#) := x"00";  m(16#FFEF#) := x"FF";
        m(16#FFEA#) := x"00";  m(16#FFEB#) := x"FF";
        m(16#FF00#) := x"40"; -- RTI

        -- Main test sequence
        m(16#0800#) := x"78"; -- SEI
        m(16#0801#) := x"18"; -- CLC
        m(16#0802#) := x"FB"; -- XCE
        m(16#0803#) := x"C2"; -- REP
        m(16#0804#) := x"30"; -- #$30
        m(16#0805#) := x"A9"; -- LDA #
        m(16#0806#) := x"34"; -- low
        m(16#0807#) := x"12"; -- high
        m(16#0808#) := x"5C"; -- JML
        m(16#0809#) := x"00"; -- low
        m(16#080A#) := x"20"; -- high
        m(16#080B#) := x"20"; -- bank
        m(16#080C#) := x"EA"; -- must not be executed if JML succeeds
        return m;
    end function;

    function init_mem_hi return mem_hi_t is
        variable m : mem_hi_t := (others => x"EA");
    begin
        m(0) := x"80"; -- $20:2000 BRA
        m(1) := x"FE"; -- *
        return m;
    end function;

    signal mem_lo : mem_lo_t := init_mem_lo;
    signal mem_hi : mem_hi_t := init_mem_hi;
    signal verbose : std_logic := '0';

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    type scenario_t is (SC_BASELINE, SC_DROP_ON_XCE, SC_DROP_AFTER_XCE,
                        SC_DROP_ON_REP_OP, SC_DROP_ON_LDA_OP1);
    signal scenario : scenario_t := SC_BASELINE;
    signal drop_done : std_logic := '0';

    signal saw_xce_fetch  : std_logic := '0';
    signal saw_post_xce   : std_logic := '0';
    signal ef_after_xce   : std_logic := '1';
    signal saw_rep_post   : std_logic := '0';
    signal p_after_rep    : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_jml_fetch  : std_logic := '0';
    signal pbr_at_jml     : std_logic_vector(7 downto 0) := (others => '0');
    signal pc_at_jml      : std_logic_vector(15 downto 0) := (others => '0');
    signal saw_target     : std_logic := '0';
    signal pbr_at_target  : std_logic_vector(7 downto 0) := (others => '0');
    signal pc_at_target   : std_logic_vector(15 downto 0) := (others => '0');

    signal done_xce       : std_logic := '0';
    signal done_rep       : std_logic := '0';
    signal done_jml       : std_logic := '0';

begin

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

    process(all)
        variable addr24 : integer;
        variable bank   : integer;
        variable offs   : integer;
    begin
        addr24 := to_integer(unsigned(a_out));
        bank   := to_integer(unsigned(a_out(23 downto 16)));
        offs   := to_integer(unsigned(a_out(15 downto 0)));

        if bank = 16#00# then
            d_in <= mem_lo(offs);
        elsif bank = 16#20# and offs >= 16#2000# and offs <= 16#2001# then
            d_in <= mem_hi(offs - 16#2000#);
        else
            d_in <= x"EA";
        end if;
    end process;

    process(clk)
        variable bank : integer;
        variable offs : integer;
    begin
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                bank := to_integer(unsigned(a_out(23 downto 16)));
                offs := to_integer(unsigned(a_out(15 downto 0)));
                if bank = 16#00# then
                    mem_lo(offs) <= d_out;
                elsif bank = 16#20# and offs >= 16#2000# and offs <= 16#2001# then
                    mem_hi(offs - 16#2000#) <= d_out;
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
            if verbose = '1' and rst_n = '1' and ce = '1' and cycle_count >= 18 and cycle_count <= 80 then
                report "TRACE " & scenario_t'image(scenario) &
                       " cyc=" & integer'image(cycle_count) &
                       " IR=$" & to_hstring(dbg_ir) &
                       " PBR=$" & to_hstring(dbg_pbr) &
                       " PC=$" & to_hstring(dbg_pc) &
                       " P=$" & to_hstring(dbg_p) &
                       " EF=" & std_logic'image(ef_out)(2) &
                       " A=$" & to_hstring(a_out) &
                       " DI=$" & to_hstring(d_in);
            end if;
        end if;
    end process;

    ce_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ce <= '1';
                drop_done <= '0';
            else
                ce <= '1';
                if drop_done = '0' then
                    if scenario = SC_DROP_ON_XCE
                       and dbg_ir = x"FB" then
                        ce <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_AFTER_XCE
                       and dbg_pc = x"0803" then
                        ce <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_ON_REP_OP
                       and dbg_ir = x"C2" and dbg_pc = x"0804" then
                        ce <= '0';
                        drop_done <= '1';
                    elsif scenario = SC_DROP_ON_LDA_OP1
                       and dbg_ir = x"A9" and dbg_pc = x"0806" then
                        ce <= '0';
                        drop_done <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                saw_xce_fetch <= '0';
                saw_post_xce  <= '0';
                saw_rep_post   <= '0';
                saw_jml_fetch  <= '0';
                saw_target     <= '0';
                done_xce       <= '0';
                done_rep       <= '0';
                done_jml       <= '0';
            elsif ce = '1' then
                if dbg_ir = x"FB" then
                    saw_xce_fetch <= '1';
                elsif saw_xce_fetch = '1' and done_xce = '0' then
                    saw_post_xce <= '1';
                    ef_after_xce <= ef_out;
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
            ef_after_xce <= '1';
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
            report "START " & scenario_t'image(sc);
            scenario <= sc;
            verbose <= '1' when sc = SC_BASELINE else '0';
            reset_observers;
            rst_n <= '0';
            wait for CLK_PERIOD * 8;
            rst_n <= '1';
            wait_for_completion;

            verbose <= '0';

            report "RESULT " & scenario_t'image(sc) &
                   " final_IR=$" & to_hstring(dbg_ir) &
                   " final_P=$" & to_hstring(dbg_p) &
                   " final_EF=" & std_logic'image(ef_out)(2) &
                   " final_PBR=$" & to_hstring(dbg_pbr) &
                   " final_PC=$" & to_hstring(dbg_pc);
        end procedure;
    begin
        run_one(SC_BASELINE);
        run_one(SC_DROP_ON_XCE);
        run_one(SC_DROP_AFTER_XCE);
        run_one(SC_DROP_ON_REP_OP);
        run_one(SC_DROP_ON_LDA_OP1);
        report "DONE bare";
        std.env.finish;
    end process;

end architecture;
