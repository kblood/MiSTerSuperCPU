-- p65c816_jml_indirect_long_tb.vhd
--
-- Tests opcode $DC = JML [zp] (jump indirect long via direct-page pointer).
--
-- This is how Doom's SCPUMIPS dispatcher at $80:$005C returns to caller:
--   80:0099  dc fc 00      JML [$00FC]
--
-- Pre-loads $00FC/$00FD/$00FE with a 24-bit target. Executes JML [$00FC].
-- PASS if PBR:PC ends up at the target, executes a sentinel write.
--
-- Test program at $00:$0800:
--   CLC; XCE       ; native
--   REP #$30       ; M=0, X=0
--   LDA #$0000; TCD ; DP=0
--   LDA #$01FF; TCS ; SP=$01FF
--   LDA #$00; PHA; PLB ; DBR=0
--   SEP #$20       ; M=1
--   LDA #$50; STA $FC  ; $FC=$50
--   LDA #$08; STA $FD  ; $FD=$08
--   LDA #$80; STA $FE  ; $FE=$80   → target = $80:$0850
--   DC FC          ; JML [$00FC]
--
-- Target at $80:$0850:
--   LDA #$77       ; (assume M=1 still)
--   STA $002000    ; (long-abs sentinel write)
--   spin: BRA -2
--
-- PASS criteria: $00:$2000 = $77 AND PBR:PC = $80:$0850-area at end.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_jml_indirect_long_tb is
end entity;

architecture sim of p65c816_jml_indirect_long_tb is

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

    -- bank 0 = $00, bank 1 = $80
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
        -- Native vectors → $FF00 (RTI sink)
        put(0, 16#FFE6#, 16#00#); put(0, 16#FFE7#, 16#FF#);
        put(0, 16#FFEE#, 16#00#); put(0, 16#FFEF#, 16#FF#);
        put(0, 16#FFEA#, 16#00#); put(0, 16#FFEB#, 16#FF#);
        put(0, 16#FFFE#, 16#00#); put(0, 16#FFFF#, 16#FF#);
        put(0, 16#FF00#, 16#40#);  -- RTI

        ----------------------------------------------------------------
        -- Test program at $00:$0800
        ----------------------------------------------------------------
        -- 18           CLC
        put(0, 16#0800#, 16#18#);
        -- FB           XCE
        put(0, 16#0801#, 16#FB#);
        -- C2 30        REP #$30
        put(0, 16#0802#, 16#C2#); put(0, 16#0803#, 16#30#);
        -- A9 00 00     LDA #$0000
        put(0, 16#0804#, 16#A9#); put(0, 16#0805#, 16#00#); put(0, 16#0806#, 16#00#);
        -- 5B           TCD
        put(0, 16#0807#, 16#5B#);
        -- A9 FF 01     LDA #$01FF
        put(0, 16#0808#, 16#A9#); put(0, 16#0809#, 16#FF#); put(0, 16#080A#, 16#01#);
        -- 1B           TCS
        put(0, 16#080B#, 16#1B#);
        -- E2 20        SEP #$20  (M=1)
        put(0, 16#080C#, 16#E2#); put(0, 16#080D#, 16#20#);
        -- A9 00        LDA #$00
        put(0, 16#080E#, 16#A9#); put(0, 16#080F#, 16#00#);
        -- 48           PHA
        put(0, 16#0810#, 16#48#);
        -- AB           PLB  (DBR=0)
        put(0, 16#0811#, 16#AB#);

        -- Set $FC = $50, $FD = $08, $FE = $80  → target $80:$0850
        -- A9 50        LDA #$50
        put(0, 16#0812#, 16#A9#); put(0, 16#0813#, 16#50#);
        -- 85 FC        STA $FC
        put(0, 16#0814#, 16#85#); put(0, 16#0815#, 16#FC#);
        -- A9 08        LDA #$08
        put(0, 16#0816#, 16#A9#); put(0, 16#0817#, 16#08#);
        -- 85 FD        STA $FD
        put(0, 16#0818#, 16#85#); put(0, 16#0819#, 16#FD#);
        -- A9 80        LDA #$80
        put(0, 16#081A#, 16#A9#); put(0, 16#081B#, 16#80#);
        -- 85 FE        STA $FE
        put(0, 16#081C#, 16#85#); put(0, 16#081D#, 16#FE#);

        -- DC FC        JML [$00FC]
        put(0, 16#081E#, 16#DC#); put(0, 16#081F#, 16#FC#); put(0, 16#0820#, 16#00#);

        -- Trap (should NOT execute) at $0821:
        --   A9 BB; 8F 00 30 00; spin
        put(0, 16#0821#, 16#A9#); put(0, 16#0822#, 16#BB#);
        put(0, 16#0823#, 16#8F#); put(0, 16#0824#, 16#00#); put(0, 16#0825#, 16#30#); put(0, 16#0826#, 16#00#);
        put(0, 16#0827#, 16#80#); put(0, 16#0828#, 16#FE#);

        ----------------------------------------------------------------
        -- Target at $80:$0850
        ----------------------------------------------------------------
        -- A9 77        LDA #$77   (M=1)
        put(1, 16#0850#, 16#A9#); put(1, 16#0851#, 16#77#);
        -- 8F 00 20 00  STA $002000  (long abs — sentinel)
        put(1, 16#0852#, 16#8F#); put(1, 16#0853#, 16#00#); put(1, 16#0854#, 16#20#); put(1, 16#0855#, 16#00#);
        -- 80 FE        BRA -2 (spin)
        put(1, 16#0856#, 16#80#); put(1, 16#0857#, 16#FE#);

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

    -- Trace fetches in bank $80 (target) and around the JML at $081E
    trace : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            if ce = '1' and vpa = '1' and vda = '1' then
                if dbg_pbr = x"80" or
                   (dbg_pbr = x"00" and unsigned(dbg_pc) >= 16#081C# and unsigned(dbg_pc) <= 16#0830#) then
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
        report "Sentinel $00:$2000 = " & to_hstring(mem(0)(16#2000#));
        report "Trap $00:$3000 = " & to_hstring(mem(0)(16#3000#));

        if mem(0)(16#2000#) = x"77" then
            report "* PASS: JML [$00FC] reached target $80:$0850 and ran sentinel" severity note;
        else
            report "* FAIL: sentinel NOT reached (got " & to_hstring(mem(0)(16#2000#)) & ")" severity error;
        end if;

        if mem(0)(16#3000#) = x"BB" then
            report "* FAIL: trap ran -- JML [$00FC] FELL THROUGH instead of taking branch" severity error;
        end if;

        report "checker done";
        wait;
    end process;

end architecture;
