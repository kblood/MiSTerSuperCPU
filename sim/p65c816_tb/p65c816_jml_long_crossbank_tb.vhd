-- p65c816_jml_long_crossbank_tb.vhd
--
-- Tests opcode $5C = JML al (jump absolute long, cross-bank).
--
-- Mirrors Doom's first cross-bank dispatch at $20:$03E6:
--   20:03E6  5C 5C 00 80   JML $80:$005C
--
-- This bench runs equivalent: starts at $00:$0800, sets up native mode,
-- then `JML $80:$0500` -- enters bank $80 directly. Target writes
-- sentinel $00:$2000=$77 then spins.
--
-- ALSO tests reverse direction: $80:$0500 does `JML $00:$0830` to verify
-- bank-$80 → bank-$00 JML al works.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_jml_long_crossbank_tb is
end entity;

architecture sim of p65c816_jml_long_crossbank_tb is

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
    signal rdy_out: std_logic;

    signal dbg_pc    : std_logic_vector(15 downto 0);
    signal dbg_sp    : std_logic_vector(15 downto 0);
    signal dbg_p     : std_logic_vector(7 downto 0);
    signal dbg_ir    : std_logic_vector(7 downto 0);
    signal dbg_pbr   : std_logic_vector(7 downto 0);
    signal dbg_dbr   : std_logic_vector(7 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type banks_t is array (0 to 1) of mem_t;

    function init_banks return banks_t is
        variable b : banks_t := (others => (others => x"EA"));
        procedure put(bk: integer; addr: integer; v: integer) is
        begin
            b(bk)(addr) := std_logic_vector(to_unsigned(v, 8));
        end procedure;
    begin
        -- Reset vector $00:$FFFC/FD → $0800
        put(0, 16#FFFC#, 16#00#);
        put(0, 16#FFFD#, 16#08#);
        put(0, 16#FF00#, 16#40#);  -- RTI sink

        ----------------------------------------------------------------
        -- Bootstrap at $00:$0800
        ----------------------------------------------------------------
        -- 18 FB        CLC; XCE
        put(0, 16#0800#, 16#18#);
        put(0, 16#0801#, 16#FB#);
        -- C2 30        REP #$30
        put(0, 16#0802#, 16#C2#); put(0, 16#0803#, 16#30#);
        -- A9 00 00 5B  LDA #$0000; TCD
        put(0, 16#0804#, 16#A9#); put(0, 16#0805#, 16#00#); put(0, 16#0806#, 16#00#);
        put(0, 16#0807#, 16#5B#);
        -- A9 FF 01 1B  LDA #$01FF; TCS
        put(0, 16#0808#, 16#A9#); put(0, 16#0809#, 16#FF#); put(0, 16#080A#, 16#01#);
        put(0, 16#080B#, 16#1B#);
        -- E2 20        SEP #$20  (M=1)
        put(0, 16#080C#, 16#E2#); put(0, 16#080D#, 16#20#);
        -- A9 00 48 AB  LDA #$00; PHA; PLB  (DBR=0)
        put(0, 16#080E#, 16#A9#); put(0, 16#080F#, 16#00#);
        put(0, 16#0810#, 16#48#); put(0, 16#0811#, 16#AB#);

        -- 5C 00 05 80  JML $80:$0500  ← FIRST CROSS-BANK JML
        put(0, 16#0812#, 16#5C#); put(0, 16#0813#, 16#00#); put(0, 16#0814#, 16#05#); put(0, 16#0815#, 16#80#);

        -- Trap at $0816 (should NOT execute)
        --   A9 BB; 8F 00 30 00; spin
        put(0, 16#0816#, 16#A9#); put(0, 16#0817#, 16#BB#);
        put(0, 16#0818#, 16#8F#); put(0, 16#0819#, 16#00#); put(0, 16#081A#, 16#30#); put(0, 16#081B#, 16#00#);
        put(0, 16#081C#, 16#80#); put(0, 16#081D#, 16#FE#);

        -- Continuation at $00:$0830 (target of return-JML from bank $80):
        --   A9 88        LDA #$88
        --   8F 00 21 00  STA $002100
        --   80 FE        spin
        put(0, 16#0830#, 16#A9#); put(0, 16#0831#, 16#88#);
        put(0, 16#0832#, 16#8F#); put(0, 16#0833#, 16#00#); put(0, 16#0834#, 16#21#); put(0, 16#0835#, 16#00#);
        put(0, 16#0836#, 16#80#); put(0, 16#0837#, 16#FE#);

        ----------------------------------------------------------------
        -- Bank $80 entry at $80:$0500
        ----------------------------------------------------------------
        -- A9 77        LDA #$77    (M=1)
        put(1, 16#0500#, 16#A9#); put(1, 16#0501#, 16#77#);
        -- 8F 00 20 00  STA $002000  (sentinel write — long abs to bank $00)
        put(1, 16#0502#, 16#8F#); put(1, 16#0503#, 16#00#); put(1, 16#0504#, 16#20#); put(1, 16#0505#, 16#00#);
        -- 5C 30 08 00  JML $00:$0830  ← REVERSE CROSS-BANK JML
        put(1, 16#0506#, 16#5C#); put(1, 16#0507#, 16#30#); put(1, 16#0508#, 16#08#); put(1, 16#0509#, 16#00#);

        return b;
    end function;

    signal mem : banks_t := init_banks;

    function bank_idx(bnk: std_logic_vector(7 downto 0)) return integer is
    begin
        if bnk = x"00" then return 0;
        elsif bnk = x"80" then return 1;
        else return -1;
        end if;
    end function;

    signal cycles : integer := 0;
    signal stop   : boolean := false;

begin

    clk_gen : process
    begin
        while not stop loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    rst_gen : process
    begin
        rst_n <= '0';
        wait for 80 ns;
        rst_n <= '1';
        wait;
    end process;

    dut : entity work.P65C816
        port map (
            CLK     => clk,
            RST_N   => rst_n,
            CE      => ce,
            RDY_IN  => '1',
            NMI_N   => '1',
            IRQ_N   => '1',
            ABORT_N => '1',
            D_IN    => d_in,
            D_OUT   => d_out,
            WE      => we_n,
            A_OUT   => a_out,
            RDY_OUT => rdy_out,
            VPA     => vpa,
            VDA     => vda,
            MLB     => mlb_s,
            VPB     => vpb_s,
            DBG_PC      => dbg_pc,
            DBG_SP      => dbg_sp,
            DBG_P       => dbg_p,
            DBG_IR      => dbg_ir,
            DBG_PBR     => dbg_pbr,
            DBG_DBR     => dbg_dbr,
            DBG_STATE   => dbg_state
        );

    d_in <= mem(0)(to_integer(unsigned(a_out(15 downto 0)))) when a_out(23 downto 16) = x"00"
       else mem(1)(to_integer(unsigned(a_out(15 downto 0)))) when a_out(23 downto 16) = x"80"
       else x"EA";

    write_proc : process(clk)
        variable bk  : integer;
        variable adr : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '1' and ce = '1' and we_n = '0' then
                bk  := bank_idx(a_out(23 downto 16));
                adr := to_integer(unsigned(a_out(15 downto 0)));
                if bk >= 0 then
                    mem(bk)(adr) <= d_out;
                end if;
            end if;
        end if;
    end process;

    counter : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            cycles <= cycles + 1;
            if cycles > 3000 then
                stop <= true;
            end if;
        end if;
    end process;

    trace : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            if ce = '1' and vpa = '1' and vda = '1' then
                if dbg_pbr = x"80" or
                   (dbg_pbr = x"00" and unsigned(dbg_pc) >= 16#0810# and unsigned(dbg_pc) <= 16#083A#) then
                    report "C=" & integer'image(cycles)
                           & " PB:PC=" & to_hstring(dbg_pbr) & ":" & to_hstring(dbg_pc)
                           & " IR=" & to_hstring(dbg_ir)
                           & " A_OUT=" & to_hstring(a_out)
                           & " D=" & to_hstring(d_in);
                end if;
            end if;
        end if;
    end process;

    checker : process
    begin
        wait until stop;
        report "=== TEST RESULT ===";
        report "Sentinel-A $00:$2000 = " & to_hstring(mem(0)(16#2000#)) & " (expect 77)";
        report "Sentinel-B $00:$2100 = " & to_hstring(mem(0)(16#2100#)) & " (expect 88)";
        report "Trap     $00:$3000 = " & to_hstring(mem(0)(16#3000#)) & " (expect EA)";

        if mem(0)(16#2000#) = x"77" then
            report "* PASS-A: JML 00->80 reached target $80:$0500" severity note;
        else
            report "* FAIL-A: target not reached" severity error;
        end if;
        if mem(0)(16#2100#) = x"88" then
            report "* PASS-B: JML 80->00 returned to $00:$0830" severity note;
        else
            report "* FAIL-B: return target not reached" severity error;
        end if;
        if mem(0)(16#3000#) = x"BB" then
            report "* FAIL: forward trap ran" severity error;
        end if;

        report "checker done";
        wait;
    end process;

end architecture;
