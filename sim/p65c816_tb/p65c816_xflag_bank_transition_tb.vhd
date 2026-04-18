-- p65c816_xflag_bank_transition_tb.vhd
--
-- Reproduces (or rules out) the Doom X-flag bank-transition bug seen on
-- real MiSTer hardware: when code runs from SuperRAM bank $2D in native
-- mode, the X flag (P bit 4) spontaneously transitions 0 -> 1 somewhere
-- in a 700-byte window. Once X=1, subsequent LDY #$xxxx is decoded as
-- 2-byte instead of 3-byte, corrupting the instruction stream.
--
-- This bench exercises the bare P65C816 core with a flat behavioral memory
-- model (no SuperRAM pipeline, no cache, no bus arbiter). If the flip
-- reproduces here it is a CPU-core bug. If it does NOT reproduce here the
-- fault must be on the system side (cache / SDRAM / bus arbitration).
--
-- Both scenarios live in a single `run_one` procedure that resets the DUT
-- and the memory arrays via a `scn_reset` strobe. mem00 and mem2d are
-- driven from ONE process only (the memory process) to avoid multi-driver
-- resolution producing 'X' bits on stack bytes.
--
-- Scenario A: SC_BANK_XFER
--   $00:0800 78          SEI
--   $00:0801 18          CLC
--   $00:0802 FB          XCE            ; emu -> native
--   $00:0803 C2 30       REP #$30       ; clear M, X (16-bit A/X/Y)
--   $00:0805 5C 00 00 2D JML $2D:0000
--
--   $2D:0000 A0 34 12    LDY #$1234     ; 3-byte (X=0); Y must == $1234
--   $2D:0003 08          PHP
--   $2D:0004 28          PLP
--   $2D:0005 A0 78 56    LDY #$5678     ; still 3-byte
--   $2D:0008 5C 00 10 2D JML $2D:1000
--   $2D:1000 80 FE       BRA *          ; spin = success trap
--
-- Scenario B: SC_BAD_STACK_P
--   Same prologue, then:
--
--   $2D:0000 A9 30 00    LDA #$0030     ; A = bad P value (M=1, X=1)
--   $2D:0003 48          PHA            ; pushes 16-bit A (low-byte first)
--   $2D:0004 28          PLP            ; P <- stack top = $30 ; X/M set!
--   $2D:0005 A0 34 12    LDY #$1234
--   $2D:0008 5C 00 10 2D JML $2D:1000
--   $2D:1000 80 FE       BRA *
--
-- Pass criteria:
--   A: REP clears M/X; PHP/PLP preserves X=0; PC reaches $2D:$1000.
--   B: PLP picks up X=1 from the bad stack P (proves CPU follows stack).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_xflag_bank_transition_tb is
end entity;

architecture sim of p65c816_xflag_bank_transition_tb is

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

    type scenario_t is (SC_BANK_XFER, SC_BAD_STACK_P);
    signal scenario   : scenario_t := SC_BANK_XFER;
    signal scn_reset  : std_logic := '0';  -- pulse to reinit memories + observers
    signal verbose    : std_logic := '0';

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    -- Observer state (all driven only from snap_proc)
    signal saw_rep_post   : std_logic := '0';
    signal p_after_rep    : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_2d_entry   : std_logic := '0';
    signal p_at_2d_entry  : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_php        : std_logic := '0';
    signal p_at_php       : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_post_plp   : std_logic := '0';
    signal p_after_plp    : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_bra_2d     : std_logic := '0';
    signal pc_at_bra_2d   : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_at_bra_2d  : std_logic_vector(7 downto 0) := (others => '0');
    signal xflag_ever_set : std_logic := '0';
    signal xflag_set_pc   : std_logic_vector(15 downto 0) := (others => '0');
    signal xflag_set_pbr  : std_logic_vector(7 downto 0) := (others => '0');
    signal xflag_set_ir   : std_logic_vector(7 downto 0) := (others => '0');

    signal in_bank2d      : std_logic := '0';

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

    -- ------------------------------------------------------------------
    -- Memory model. mem00/mem2d are PROCESS-LOCAL variables so there is
    -- exactly one driver for every address. The process runs on every
    -- clk edge, handles writes, and reinitialises on `scn_reset` pulse.
    -- `d_in` is driven combinationally from whichever bank the CPU is
    -- addressing.
    -- ------------------------------------------------------------------
    mem_proc: process(clk, scn_reset, a_out, scenario)
        type mem_bank_t is array (0 to 65535) of std_logic_vector(7 downto 0);
        variable mem00 : mem_bank_t := (others => x"EA");
        variable mem2d : mem_bank_t := (others => x"EA");
        variable bank  : integer;
        variable offs  : integer;

        procedure reload_bank00 is
        begin
            mem00 := (others => x"EA");
            -- reset vector -> $0800
            mem00(16#FFFC#) := x"00";
            mem00(16#FFFD#) := x"08";
            -- IRQ/BRK/NMI vectors -> RTI @ $FF00
            mem00(16#FFFE#) := x"00";  mem00(16#FFFF#) := x"FF";
            mem00(16#FFE6#) := x"00";  mem00(16#FFE7#) := x"FF";
            mem00(16#FFEE#) := x"00";  mem00(16#FFEF#) := x"FF";
            mem00(16#FFEA#) := x"00";  mem00(16#FFEB#) := x"FF";
            mem00(16#FF00#) := x"40";  -- RTI
            -- Zero stack page so PHP/PLP see clean bytes
            for i in 16#0100# to 16#01FF# loop
                mem00(i) := x"00";
            end loop;
            -- Prologue at $0800
            mem00(16#0800#) := x"78"; -- SEI
            mem00(16#0801#) := x"18"; -- CLC
            mem00(16#0802#) := x"FB"; -- XCE
            mem00(16#0803#) := x"C2"; -- REP
            mem00(16#0804#) := x"30"; -- #$30
            mem00(16#0805#) := x"5C"; -- JML
            mem00(16#0806#) := x"00";
            mem00(16#0807#) := x"00";
            mem00(16#0808#) := x"2D";
        end procedure;

        procedure reload_bank2d_xfer is
        begin
            mem2d := (others => x"EA");
            mem2d(16#0000#) := x"A0"; -- LDY #
            mem2d(16#0001#) := x"34";
            mem2d(16#0002#) := x"12";
            mem2d(16#0003#) := x"08"; -- PHP
            mem2d(16#0004#) := x"28"; -- PLP
            mem2d(16#0005#) := x"A0"; -- LDY #
            mem2d(16#0006#) := x"78";
            mem2d(16#0007#) := x"56";
            mem2d(16#0008#) := x"5C"; -- JML
            mem2d(16#0009#) := x"00";
            mem2d(16#000A#) := x"10";
            mem2d(16#000B#) := x"2D";
            mem2d(16#1000#) := x"80"; -- BRA
            mem2d(16#1001#) := x"FE";
        end procedure;

        procedure reload_bank2d_bad_stack is
        begin
            mem2d := (others => x"EA");
            mem2d(16#0000#) := x"A9"; -- LDA #
            mem2d(16#0001#) := x"30";
            mem2d(16#0002#) := x"00";
            mem2d(16#0003#) := x"48"; -- PHA
            mem2d(16#0004#) := x"28"; -- PLP
            mem2d(16#0005#) := x"A0"; -- LDY #
            mem2d(16#0006#) := x"34";
            mem2d(16#0007#) := x"12";
            mem2d(16#0008#) := x"5C"; -- JML
            mem2d(16#0009#) := x"00";
            mem2d(16#000A#) := x"10";
            mem2d(16#000B#) := x"2D";
            mem2d(16#1000#) := x"80";
            mem2d(16#1001#) := x"FE";
        end procedure;
    begin
        -- Reload on scn_reset pulse (covers both fresh and scenario swap)
        if scn_reset = '1' then
            reload_bank00;
            if scenario = SC_BANK_XFER then
                reload_bank2d_xfer;
            else
                reload_bank2d_bad_stack;
            end if;
        end if;

        -- Writes on clock edge
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                bank := to_integer(unsigned(a_out(23 downto 16)));
                offs := to_integer(unsigned(a_out(15 downto 0)));
                if bank = 16#00# then
                    mem00(offs) := d_out;
                elsif bank = 16#2D# then
                    mem2d(offs) := d_out;
                end if;
            end if;
        end if;

        -- Combinational read on address
        bank := to_integer(unsigned(a_out(23 downto 16)));
        offs := to_integer(unsigned(a_out(15 downto 0)));
        if bank = 16#00# then
            d_in <= mem00(offs);
        elsif bank = 16#2D# then
            d_in <= mem2d(offs);
        else
            d_in <= x"EA";
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
            if verbose = '1' and rst_n = '1' and ce = '1' then
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

    in_bank2d <= '1' when dbg_pbr = x"2D" else '0';

    snap_proc: process(clk)
    begin
        if rising_edge(clk) then
            if scn_reset = '1' then
                -- Clear observer state on scenario reset pulse (same process
                -- that drives these signals -- no multi-driver conflict)
                saw_rep_post   <= '0';
                p_after_rep    <= (others => '0');
                saw_2d_entry   <= '0';
                p_at_2d_entry  <= (others => '0');
                saw_php        <= '0';
                p_at_php       <= (others => '0');
                saw_post_plp   <= '0';
                p_after_plp    <= (others => '0');
                saw_bra_2d     <= '0';
                pc_at_bra_2d   <= (others => '0');
                pbr_at_bra_2d  <= (others => '0');
                xflag_ever_set <= '0';
                xflag_set_pc   <= (others => '0');
                xflag_set_pbr  <= (others => '0');
                xflag_set_ir   <= (others => '0');
            elsif rst_n = '1' and ce = '1' then
                if saw_rep_post = '0' and dbg_pbr = x"00"
                   and dbg_ir = x"5C" and dbg_pc = x"0805" then
                    saw_rep_post <= '1';
                    p_after_rep  <= dbg_p;
                end if;

                if saw_2d_entry = '0' and dbg_pbr = x"2D" then
                    saw_2d_entry  <= '1';
                    p_at_2d_entry <= dbg_p;
                end if;

                if scenario = SC_BANK_XFER and saw_php = '0'
                   and dbg_pbr = x"2D" and dbg_ir = x"08"
                   and dbg_pc = x"0003" then
                    saw_php  <= '1';
                    p_at_php <= dbg_p;
                end if;

                -- Capture P the FIRST time the opcode following PLP has
                -- retired. In Scenario A the next op is LDY ($A0) at
                -- $2D:$0005 (PHP pushes 1 byte, PLP restores). In Scenario
                -- B the next op is also LDY ($A0) at $2D:$0005 (PHA pushed
                -- 16-bit A, PLP pulls 1 byte, SP moves by one -- imbalance
                -- is intentional to simulate a bad stack frame).
                -- Note: when IR latches $A0 the CPU has already advanced
                -- dbg_pc to at least $0006, so we do NOT constrain PC and
                -- just match on PBR+IR and the one-shot guard.
                if saw_post_plp = '0' and dbg_pbr = x"2D"
                   and dbg_ir = x"A0" then
                    saw_post_plp <= '1';
                    p_after_plp  <= dbg_p;
                end if;

                if saw_bra_2d = '0' and dbg_pbr = x"2D" and dbg_ir = x"80" then
                    saw_bra_2d     <= '1';
                    pc_at_bra_2d   <= dbg_pc;
                    pbr_at_bra_2d  <= dbg_pbr;
                end if;

                if scenario = SC_BANK_XFER and xflag_ever_set = '0'
                   and in_bank2d = '1' and dbg_p(4) = '1' then
                    xflag_ever_set <= '1';
                    xflag_set_pc   <= dbg_pc;
                    xflag_set_pbr  <= dbg_pbr;
                    xflag_set_ir   <= dbg_ir;
                end if;
            end if;
        end if;
    end process;

    main_proc: process

        procedure run_one(sc : scenario_t) is
        begin
            report "START " & scenario_t'image(sc);
            scenario <= sc;
            verbose  <= '1';
            rst_n    <= '0';
            scn_reset <= '1';
            wait for CLK_PERIOD * 4;
            scn_reset <= '0';
            wait for CLK_PERIOD * 4;
            rst_n <= '1';
            wait for 8 us;
            verbose <= '0';

            report "RESULT " & scenario_t'image(sc) &
                   " P_after_REP=$"    & to_hstring(p_after_rep) &
                   " P_at_2D_entry=$"  & to_hstring(p_at_2d_entry) &
                   " P_at_PHP=$"       & to_hstring(p_at_php) &
                   " P_after_PLP=$"    & to_hstring(p_after_plp) &
                   " PBR_at_BRA=$"     & to_hstring(pbr_at_bra_2d) &
                   " PC_at_BRA=$"      & to_hstring(pc_at_bra_2d) &
                   " xflag_flipped="   & std_logic'image(xflag_ever_set)(2);

            if sc = SC_BANK_XFER then
                if p_after_rep(4) /= '0' or p_after_rep(5) /= '0' then
                    report "FAIL(A): REP #$30 did not clear M/X (P=$"
                           & to_hstring(p_after_rep) & ")" severity warning;
                else
                    report "PASS(A): REP #$30 cleared M and X" severity note;
                end if;

                if p_after_plp(4) /= '0' then
                    report "FAIL(A): PHP/PLP left X=1, reproduces bug at PC=$"
                           & to_hstring(xflag_set_pc) & " IR=$"
                           & to_hstring(xflag_set_ir) severity warning;
                else
                    report "PASS(A): PHP/PLP preserved X=0" severity note;
                end if;

                -- BRA trap lives at $2D:$1000 but IR latches after PC has
                -- already advanced past the operand, so PC at first $80
                -- observation is typically $1001 or $1002. Accept the
                -- whole 3-byte window as PASS.
                if pbr_at_bra_2d = x"2D"
                   and (pc_at_bra_2d = x"1000"
                        or pc_at_bra_2d = x"1001"
                        or pc_at_bra_2d = x"1002") then
                    report "PASS(A): Reached $2D:$1000 trap via both 3-byte LDYs"
                           severity note;
                else
                    report "FAIL(A): BRA trap not reached near $2D:$1000 (got $"
                           & to_hstring(pbr_at_bra_2d) & ":$"
                           & to_hstring(pc_at_bra_2d) & ")" severity warning;
                end if;

                if xflag_ever_set = '1' then
                    report "FAIL(A): X flag spontaneously set in bank $2D at PC=$"
                           & to_hstring(xflag_set_pc) & " IR=$"
                           & to_hstring(xflag_set_ir) severity warning;
                else
                    report "PASS(A): X flag stayed 0 throughout bank $2D"
                           severity note;
                end if;

            else  -- SC_BAD_STACK_P
                if p_after_plp(4) = '1' then
                    report "PASS(B): PLP followed stack and set X=1 as expected"
                           severity note;
                else
                    report "FAIL(B): PLP did NOT pick up X=1 from stack (P=$"
                           & to_hstring(p_after_plp) & ")" severity warning;
                end if;
            end if;
        end procedure;

    begin
        run_one(SC_BANK_XFER);
        run_one(SC_BAD_STACK_P);
        report "DONE xflag_bank_transition";
        std.env.finish;
    end process;

end architecture;
