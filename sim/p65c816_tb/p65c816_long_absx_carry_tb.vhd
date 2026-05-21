-- p65c816_long_absx_carry_tb.vhd
--
-- Tests BF/9F long-abs,X with X causing the low byte of the address
-- to wrap from $FF -> $00 (carry into high byte). This is exactly
-- Doom's prologue first copy at $20:$02F2:
--
--   SEP #$20            ; M=1 (8-bit accum)
--   LDX #$00FF          ; X=$FF (16-bit X)
--   loop:
--     LDA $200124,X     ; opcode BF, source $20:$0124+X = $0124..$0223
--     STA $000200,X     ; opcode 9F, dest   $00:$0200+X
--     DEX
--     BPL loop
--
-- Source low byte crosses $FF->$00 at X=$DC; high byte must increment
-- from $01 to $02 in that case.
--
-- Replicated here with bank $80 source (so we still cover the cross-bank
-- path), and a 256-byte unique-pattern fill so any byte mis-mapped is
-- visible in the output.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_long_absx_carry_tb is
end entity;

architecture sim of p65c816_long_absx_carry_tb is

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
        put(0, 16#FFFC#, 16#00#);
        put(0, 16#FFFD#, 16#08#);
        put(0, 16#FF00#, 16#40#);

        ----------------------------------------------------------------
        -- Test program at $00:$0800
        ----------------------------------------------------------------
        -- 18 FB        CLC; XCE         (native)
        put(0, 16#0800#, 16#18#);
        put(0, 16#0801#, 16#FB#);
        -- C2 30        REP #$30         (M=0, X=0)
        put(0, 16#0802#, 16#C2#); put(0, 16#0803#, 16#30#);
        -- A9 00 00 5B  LDA #$0000; TCD
        put(0, 16#0804#, 16#A9#); put(0, 16#0805#, 16#00#); put(0, 16#0806#, 16#00#);
        put(0, 16#0807#, 16#5B#);
        -- A9 FF 01 1B  LDA #$01FF; TCS
        put(0, 16#0808#, 16#A9#); put(0, 16#0809#, 16#FF#); put(0, 16#080A#, 16#01#);
        put(0, 16#080B#, 16#1B#);
        -- A9 00 48 AB  LDA #$00; PHA; PLB (DBR=0; M still 0)
        put(0, 16#080C#, 16#A9#); put(0, 16#080D#, 16#00#);
        put(0, 16#080E#, 16#48#); put(0, 16#080F#, 16#AB#);
        -- E2 20        SEP #$20         (M=1)
        put(0, 16#0810#, 16#E2#); put(0, 16#0811#, 16#20#);
        -- A2 FF 00     LDX #$00FF       (16-bit X)
        put(0, 16#0812#, 16#A2#); put(0, 16#0813#, 16#FF#); put(0, 16#0814#, 16#00#);

        -- Loop at $0815:
        -- BF 24 01 80  LDA $80:$0124,X     (4 bytes)
        put(0, 16#0815#, 16#BF#); put(0, 16#0816#, 16#24#); put(0, 16#0817#, 16#01#); put(0, 16#0818#, 16#80#);
        -- 9F 00 02 00  STA $00:$0200,X     (4 bytes)
        put(0, 16#0819#, 16#9F#); put(0, 16#081A#, 16#00#); put(0, 16#081B#, 16#02#); put(0, 16#081C#, 16#00#);
        -- CA           DEX
        put(0, 16#081D#, 16#CA#);
        -- 10 F5        BPL -11 -> $0815  (offset = $0815 - $0820 = -$0B = $F5)
        put(0, 16#081E#, 16#10#); put(0, 16#081F#, 16#F5#);

        -- After loop:
        -- A9 77        LDA #$77
        put(0, 16#0820#, 16#A9#); put(0, 16#0821#, 16#77#);
        -- 8F 00 30 00  STA $003000     (sentinel)
        put(0, 16#0822#, 16#8F#); put(0, 16#0823#, 16#00#); put(0, 16#0824#, 16#30#); put(0, 16#0825#, 16#00#);
        -- 80 FE        spin
        put(0, 16#0826#, 16#80#); put(0, 16#0827#, 16#FE#);

        ----------------------------------------------------------------
        -- Bank $80 source pattern: $80:$0124..$80:$0223 = 256 unique bytes
        -- Pattern: byte_at($0124+i) = i XOR $A5  (each byte unique, easy to verify)
        ----------------------------------------------------------------
        -- Pattern: byte_at($0124+i) = i  (each byte = its index, 0..255)
        for i in 0 to 255 loop
            put(1, 16#0124# + i, i);
        end loop;

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
            -- 256 iterations * ~12 cycles each = ~3000 cycles plus overhead
            if cycles > 8000 then
                stop <= true;
            end if;
        end if;
    end process;

    checker : process
        variable expected : std_logic_vector(7 downto 0);
        variable mismatches : integer := 0;
    begin
        wait until stop;
        report "=== TEST RESULT ===";
        report "Sentinel $00:$3000 = " & to_hstring(mem(0)(16#3000#)) & " (expect 77)";

        if mem(0)(16#3000#) /= x"77" then
            report "* FAIL: sentinel not reached -- copy loop hung or trap"
                   severity error;
        else
            report "* sentinel reached, copy loop completed";
        end if;

        -- Verify all 256 bytes: dest at $0200+i should equal src at $0124+i = i
        for i in 0 to 255 loop
            expected := std_logic_vector(to_unsigned(i, 8));
            if mem(0)(16#0200# + i) /= expected then
                report "FAIL: $00:$0" & to_hstring(std_logic_vector(to_unsigned(16#0200# + i, 16)))
                       & " = " & to_hstring(mem(0)(16#0200# + i))
                       & " expected " & to_hstring(expected)
                       severity error;
                mismatches := mismatches + 1;
            end if;
        end loop;

        if mismatches = 0 then
            report "* PASS: all 256 bytes copied correctly across $FF->$00 carry"
                   severity note;
        else
            report "* FAIL: " & integer'image(mismatches) & " mismatches"
                   severity error;
        end if;

        -- Show a few diagnostic bytes spanning the carry boundary
        report "Diagnostic spread (each dest byte should equal X):";
        report "  $0200 = " & to_hstring(mem(0)(16#0200#)) & " (X=00, src $0124, exp 00)";
        report "  $0223 = " & to_hstring(mem(0)(16#0223#)) & " (X=23, src $0147, exp 23)";
        report "  $02DA = " & to_hstring(mem(0)(16#02DA#)) & " (X=DA, src $01FE, exp DA)";
        report "  $02DB = " & to_hstring(mem(0)(16#02DB#)) & " (X=DB, src $01FF, exp DB)";
        report "  -- carry boundary X=DC, src low FE/FF -> 00 [HIGH BYTE INC]";
        report "  $02DC = " & to_hstring(mem(0)(16#02DC#)) & " (X=DC, src $0200, exp DC)";
        report "  $02DD = " & to_hstring(mem(0)(16#02DD#)) & " (X=DD, src $0201, exp DD)";
        report "  $02FF = " & to_hstring(mem(0)(16#02FF#)) & " (X=FF, src $0223, exp FF)";

        report "checker done";
        wait;
    end process;

end architecture;
