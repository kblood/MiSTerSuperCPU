-- p65c816_scpumips_copy_tb.vhd
--
-- Reproduces Doom's first cross-bank dispatch: the SCPUMIPS handler at
-- $80:$005C does three long-abs,X copies (LDA al,X / STA al,X) from
-- bank $80 to bank $00.
--
-- Hypothesis under test: P65C816 native-mode `LDA al,X` ($BF) and
-- `STA al,X` ($9F) opcodes are buggy — Doom's prologue copies wrong
-- bytes into bank $00:$0800-$0FB7, corrupting the JML[$74] dispatcher
-- helpers, which then read stale loader-leftover $FC=$5C and JML to
-- the trap at $2C:$A95C.
--
-- Test program (loaded at $20:$0000, reset vector points there):
--   Native-mode bootstrap:
--     CLC; XCE         ; → native (E=0, C=1)
--     REP #$30         ; M=0, X=0 (16-bit)
--     LDA #$0000; TCD  ; DP=0
--     LDA #$01FF; TCS  ; SP=$01FF
--     LDA #$00; PHA; PLB ; DBR=0
--     SEP #$20         ; M=1 (matches Doom's $80:$005C entry)
--     LDX #$0000       ; X=0 (16-bit X)
--     -- copy 16 bytes from $80:$1234,X to $00:$2000,X
--     loop:
--       CPX #$0010
--       BEQ done
--       LDA $801234,X    ; opcode $BF (long-abs,X)
--       STA $002000,X    ; opcode $9F (long-abs,X)
--       INX
--       BRA loop
--     done:
--       LDA #$77
--       STA $003000      ; sentinel — test passes if $00:$3000 = $77
--       JMP done_spin
--     done_spin: JMP done_spin
--
-- Source $80:$1234-$1243 = sequence $C0..$CF
-- Expected dest $00:$2000-$200F = same sequence
--
-- PASS criteria:
--   * $00:$3000 == $77 (sentinel)
--   * $00:$2000-$200F == $C0..$CF (16 bytes copied correctly)
--
-- A multi-bank memory model is needed since source is in bank $80.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_scpumips_copy_tb is
end entity;

architecture sim of p65c816_scpumips_copy_tb is

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

    -- Two banks of memory: bank $00 (general) + bank $80 (source data + code)
    -- Layout:
    --   bank 0 = bank $00 (RAM/zp/stack/test sentinels)
    --   bank 1 = bank $80 (source data only — code can stay in bank $00)
    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type banks_t is array (0 to 1) of mem_t;

    function init_banks return banks_t is
        variable b : banks_t := (others => (others => x"EA"));  -- $EA = NOP

        procedure put(bk: integer; addr: integer; v: integer) is
        begin
            b(bk)(addr) := std_logic_vector(to_unsigned(v, 8));
        end procedure;
    begin
        ----------------------------------------------------------------
        -- Bank $00 (bk=0): vectors + program code
        ----------------------------------------------------------------

        -- Reset vector $00:$FFFC/FD → $0800
        put(0, 16#FFFC#, 16#00#);
        put(0, 16#FFFD#, 16#08#);
        -- Native vectors → $FF00 (RTI sink)
        put(0, 16#FFE6#, 16#00#); put(0, 16#FFE7#, 16#FF#);  -- BRK-N
        put(0, 16#FFEE#, 16#00#); put(0, 16#FFEF#, 16#FF#);  -- IRQ-N
        put(0, 16#FFEA#, 16#00#); put(0, 16#FFEB#, 16#FF#);  -- NMI-N
        put(0, 16#FFFE#, 16#00#); put(0, 16#FFFF#, 16#FF#);  -- IRQ-emu
        put(0, 16#FF00#, 16#40#);  -- RTI

        ----------------------------------------------------------------
        -- Test program at $00:$0800
        ----------------------------------------------------------------
        -- $0800: 18           CLC
        put(0, 16#0800#, 16#18#);
        -- $0801: FB           XCE        ; → native (E=0, C=1)
        put(0, 16#0801#, 16#FB#);
        -- $0802: C2 30        REP #$30   ; M=0, X=0
        put(0, 16#0802#, 16#C2#); put(0, 16#0803#, 16#30#);
        -- $0804: A9 00 00     LDA #$0000
        put(0, 16#0804#, 16#A9#); put(0, 16#0805#, 16#00#); put(0, 16#0806#, 16#00#);
        -- $0807: 5B           TCD        ; DP=0
        put(0, 16#0807#, 16#5B#);
        -- $0808: A9 FF 01     LDA #$01FF
        put(0, 16#0808#, 16#A9#); put(0, 16#0809#, 16#FF#); put(0, 16#080A#, 16#01#);
        -- $080B: 1B           TCS        ; SP=$01FF
        put(0, 16#080B#, 16#1B#);
        -- $080C: E2 20        SEP #$20   ; M=1
        put(0, 16#080C#, 16#E2#); put(0, 16#080D#, 16#20#);
        -- $080E: A9 00        LDA #$00
        put(0, 16#080E#, 16#A9#); put(0, 16#080F#, 16#00#);
        -- $0810: 48           PHA
        put(0, 16#0810#, 16#48#);
        -- $0811: AB           PLB        ; DBR=0
        put(0, 16#0811#, 16#AB#);
        -- $0812: A2 00 00     LDX #$0000 ; X=0 (16-bit X — set by REP)
        put(0, 16#0812#, 16#A2#); put(0, 16#0813#, 16#00#); put(0, 16#0814#, 16#00#);

        -- Loop start $0815:
        --   E0 10 00     CPX #$0010
        put(0, 16#0815#, 16#E0#); put(0, 16#0816#, 16#10#); put(0, 16#0817#, 16#00#);
        --   F0 0B        BEQ +$0B → $0824 (done)
        put(0, 16#0818#, 16#F0#); put(0, 16#0819#, 16#0B#);
        --   BF 34 12 80  LDA $801234,X    ; long-abs,X load
        put(0, 16#081A#, 16#BF#); put(0, 16#081B#, 16#34#); put(0, 16#081C#, 16#12#); put(0, 16#081D#, 16#80#);
        --   9F 00 20 00  STA $002000,X    ; long-abs,X store
        put(0, 16#081E#, 16#9F#); put(0, 16#081F#, 16#00#); put(0, 16#0820#, 16#20#); put(0, 16#0821#, 16#00#);
        --   E8           INX
        put(0, 16#0822#, 16#E8#);
        --   80 F1        BRA -$0F → $0815  (loop)
        put(0, 16#0823#, 16#80#); put(0, 16#0824#, 16#F1#);

        -- Wait — BEQ from $0818 with offset $0B targets $081A+$0B = $0825.
        -- Let me redo: BEQ at $0818 (2 bytes), next instr at $081A, +$0B → $0825 (done).
        -- But that's WHERE we're putting code. Let me recompute:
        --   $0815: E0 10 00     CPX #$0010   (3 bytes, ends at $0817)
        --   $0818: F0 ??        BEQ done
        --   $081A: BF 34 12 80  LDA $801234,X (4 bytes, ends at $081D)
        --   $081E: 9F 00 20 00  STA $002000,X (4 bytes, ends at $0821)
        --   $0822: E8           INX
        --   $0823: 80 F0        BRA $0815 (offset = $0815 - $0825 = -$10)
        --   $0825: done       (sentinel block)
        --
        -- BEQ at $0818, offset = ($0825 - $081A) = $0B ✓
        -- BRA at $0823, offset = ($0815 - $0825) = -$10 ($F0)
        put(0, 16#0824#, 16#F0#);  -- BRA offset (overwrites placeholder)

        -- Done at $0825:
        --   A9 77        LDA #$77    (M=1)
        put(0, 16#0825#, 16#A9#); put(0, 16#0826#, 16#77#);
        --   8F 00 30 00  STA $003000  (long abs — sentinel write)
        put(0, 16#0827#, 16#8F#); put(0, 16#0828#, 16#00#); put(0, 16#0829#, 16#30#); put(0, 16#082A#, 16#00#);
        --   80 FE        BRA -2 (spin)
        put(0, 16#082B#, 16#80#); put(0, 16#082C#, 16#FE#);

        ----------------------------------------------------------------
        -- Bank $80 (bk=1): source data at $1234-$1243
        ----------------------------------------------------------------
        for i in 0 to 15 loop
            put(1, 16#1234# + i, 16#C0# + i);  -- $C0, $C1, ... $CF
        end loop;

        return b;
    end function;

    signal mem : banks_t := init_banks;

    -- Bank index helper
    function bank_idx(bnk: std_logic_vector(7 downto 0)) return integer is
    begin
        if bnk = x"00" then return 0;
        elsif bnk = x"80" then return 1;
        else return -1;  -- unmapped
        end if;
    end function;

    signal cycles : integer := 0;
    signal stop   : boolean := false;

begin

    -- Clock generator
    clk_gen : process
    begin
        while not stop loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    -- Reset (active-low, holds for 4 cycles)
    rst_gen : process
    begin
        rst_n <= '0';
        wait for 80 ns;
        rst_n <= '1';
        wait;
    end process;

    -- DUT
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

    -- Combinational read; clocked write
    -- Bank dispatch via address high byte
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

    -- Cycle counter + termination
    counter : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            cycles <= cycles + 1;
            -- Stop after 5000 cycles (more than enough for 16-byte copy)
            if cycles > 5000 then
                stop <= true;
            end if;
        end if;
    end process;

    -- Trace key events: only opcodes BF and 9F when VPA=1 + VDA=1 (instr fetch)
    trace : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            -- Trace every fetch with state change (verbose)
            if ce = '1' and vpa = '1' and vda = '1' then
                report "C=" & integer'image(cycles)
                       & " PB:PC=" & to_hstring(dbg_pbr) & ":" & to_hstring(dbg_pc)
                       & " IR=" & to_hstring(dbg_ir)
                       & " A_OUT=" & to_hstring(a_out)
                       & " D=" & to_hstring(d_in)
                       & " WE=" & std_logic'image(we_n);
            end if;
        end if;
    end process;

    -- Pass/fail check
    checker : process
    begin
        wait until stop;
        report "=== TEST RESULT ===";
        report "Sentinel $00:$3000 = " & to_hstring(mem(0)(16#3000#));
        report "Dest $00:$2000-$200F:";
        for i in 0 to 15 loop
            report "  $200" & to_hstring(std_logic_vector(to_unsigned(i, 4)))
                   & " = " & to_hstring(mem(0)(16#2000# + i));
        end loop;

        if mem(0)(16#3000#) = x"77" then
            report "* PASS: sentinel reached" severity note;
        else
            report "* FAIL: sentinel NOT reached (got " & to_hstring(mem(0)(16#3000#)) & ")" severity error;
        end if;

        for i in 0 to 15 loop
            if mem(0)(16#2000# + i) /= std_logic_vector(to_unsigned(16#C0# + i, 8)) then
                report "* FAIL: dest[" & integer'image(i) & "] = "
                       & to_hstring(mem(0)(16#2000# + i)) & " expected "
                       & to_hstring(std_logic_vector(to_unsigned(16#C0# + i, 8))) severity error;
            end if;
        end loop;
        report "checker done";
        wait;
    end process;

end architecture;
