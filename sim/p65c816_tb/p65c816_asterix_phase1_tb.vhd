-- p65c816_asterix_phase1_tb.vhd
--
-- Replicates Asterix's phase-1 relocator (at $0820-$085B) verbatim to test
-- if the bare P65C816 CPU core correctly exits with Y=$00 after the nested
-- copy loop. If it does, the hardware hang is system-side (bus/cache/BRAM)
-- and NOT a CPU bug. If Y=$FF at phase-2 entry on hardware only, something
-- about the SuperCPU integration is corrupting Y.
--
-- Exact phase-1 code (decoded from asterix.prg):
--   $0820 78          SEI
--   $0821 A9 0B       LDA #$0B            (we'll skip $D011 write — flat mem)
--   $0823 8D 11 D0    STA $D011
--   $0826 A9 34       LDA #$34
--   $0828 85 01       STA $01             (ROM out, RAM visible)
--   $082A A2 05       LDX #$05
--   $082C BD 5E 08    LDA $085E,X         (copy 6 bytes to ZP $2D-$32)
--   $082F 9D 2D 00    STA $002D,X
--   $0832 CA          DEX
--   $0833 10 F7       BPL $082C
--   $0835 9A          TXS                 (X=$FF -> SP=$01FF)
--   $0836 A0 00       LDY #$00
--   $0838 C6 32       DEC $32             (source-hi self-mod)
--   $083A CE 41 08    DEC $0841           (dest-hi self-mod)
--   $083D B1 31       LDA ($31),Y
--   $083F 99 00 00    STA $0000,Y         (target high byte decremented)
--   $0842 E6 01       INC $01             (I/O on)
--   $0844 8D 20 D0    STA $D020           (border color)
--   $0847 C6 01       DEC $01             (I/O off)
--   $0849 C8          INY
--   $084A D0 F1       BNE $083D           (inner loop 256 iters)
--   $084C A5 32       LDA $32
--   $084E C9 08       CMP #$08
--   $0850 D0 E6       BNE $0838           (outer loop, 183 iters total)
--   $0852 B9 64 08    LDA $0864,Y         (phase-2 entry: Y should be $00)
--   $0855 99 00 01    STA $0100,Y
--   $0858 C8          INY
--   $0859 D0 F7       BNE $0852
--   $085B 4C 00 01    JMP $0100
--
-- Data bytes:
--   $085E..$0863 = 01 08 C5 49 94 BF (copied to ZP $2D-$32)
--   After ZP copy: $2D=01 $2E=08 $2F=C5 $30=49 $31=94 $32=BF
--
-- Pass criteria: $0100-$01FF is populated (phase-2 ran) and observer sees
-- PC=$0852 once with Y=$00.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity p65c816_asterix_phase1_tb is
end entity;

architecture sim of p65c816_asterix_phase1_tb is

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
    signal dbg_x     : std_logic_vector(15 downto 0);
    signal dbg_y     : std_logic_vector(15 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    function init_mem return mem_t is
        variable m : mem_t := (others => x"EA");
    begin
        m(16#FFFC#) := x"20";  m(16#FFFD#) := x"08";   -- reset → $0820
        m(16#FFFE#) := x"00";  m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";

        -- ==== PHASE-1 CODE ====
        m(16#0820#) := x"78";                                             -- SEI
        m(16#0821#) := x"A9"; m(16#0822#) := x"0B";                       -- LDA #$0B
        m(16#0823#) := x"8D"; m(16#0824#) := x"11"; m(16#0825#) := x"D0"; -- STA $D011
        m(16#0826#) := x"A9"; m(16#0827#) := x"34";                       -- LDA #$34
        m(16#0828#) := x"85"; m(16#0829#) := x"01";                       -- STA $01
        m(16#082A#) := x"A2"; m(16#082B#) := x"05";                       -- LDX #$05
        m(16#082C#) := x"BD"; m(16#082D#) := x"5E"; m(16#082E#) := x"08"; -- LDA $085E,X
        m(16#082F#) := x"9D"; m(16#0830#) := x"2D"; m(16#0831#) := x"00"; -- STA $002D,X
        m(16#0832#) := x"CA";                                             -- DEX
        m(16#0833#) := x"10"; m(16#0834#) := x"F7";                       -- BPL $082C
        m(16#0835#) := x"9A";                                             -- TXS
        m(16#0836#) := x"A0"; m(16#0837#) := x"00";                       -- LDY #$00
        m(16#0838#) := x"C6"; m(16#0839#) := x"32";                       -- DEC $32
        m(16#083A#) := x"CE"; m(16#083B#) := x"41"; m(16#083C#) := x"08"; -- DEC $0841
        m(16#083D#) := x"B1"; m(16#083E#) := x"31";                       -- LDA ($31),Y
        m(16#083F#) := x"99"; m(16#0840#) := x"00"; m(16#0841#) := x"00"; -- STA $0000,Y
        m(16#0842#) := x"E6"; m(16#0843#) := x"01";                       -- INC $01
        m(16#0844#) := x"8D"; m(16#0845#) := x"20"; m(16#0846#) := x"D0"; -- STA $D020
        m(16#0847#) := x"C6"; m(16#0848#) := x"01";                       -- DEC $01
        m(16#0849#) := x"C8";                                             -- INY
        m(16#084A#) := x"D0"; m(16#084B#) := x"F1";                       -- BNE $083D
        m(16#084C#) := x"A5"; m(16#084D#) := x"32";                       -- LDA $32
        m(16#084E#) := x"C9"; m(16#084F#) := x"08";                       -- CMP #$08
        m(16#0850#) := x"D0"; m(16#0851#) := x"E6";                       -- BNE $0838
        -- phase-2
        m(16#0852#) := x"B9"; m(16#0853#) := x"64"; m(16#0854#) := x"08"; -- LDA $0864,Y
        m(16#0855#) := x"99"; m(16#0856#) := x"00"; m(16#0857#) := x"01"; -- STA $0100,Y
        m(16#0858#) := x"C8";                                             -- INY
        m(16#0859#) := x"D0"; m(16#085A#) := x"F7";                       -- BNE $0852
        m(16#085B#) := x"4C"; m(16#085C#) := x"00"; m(16#085D#) := x"01"; -- JMP $0100

        -- ZP init data copied from $085E-$0863
        m(16#085E#) := x"01"; m(16#085F#) := x"08";
        m(16#0860#) := x"C5"; m(16#0861#) := x"49";
        m(16#0862#) := x"94"; m(16#0863#) := x"BF";

        -- Phase-2 source $0864-$0963: marker pattern so we can verify copy
        -- ran. Byte at $0864+i = (i XOR $A5). $0100+i should match.
        for i in 0 to 255 loop
            m(16#0864# + i) := std_logic_vector(to_unsigned(i, 8) xor x"A5");
        end loop;

        -- $0100 is "JMP $0100" after phase-2 writes it. But phase-2 writes
        -- its own payload there. Pre-fill with distinct sentinel so we can
        -- tell the copy happened.
        for i in 0 to 255 loop
            m(16#0100# + i) := x"5A";
        end loop;

        -- Source data for phase-1 inner copies: fill $0894-$BFFF with
        -- index-based pattern. Phase-1 iterates $32 = $BE..$08 (183 passes)
        -- reading $32:94 + Y (so spans $BE94..$08FF roughly). Content
        -- doesn't matter for the bench — we only care about Y/PC flow.
        for i in 16#0894# to 16#BFFF# loop
            m(i) := std_logic_vector(to_unsigned(i mod 256, 8));
        end loop;

        return m;
    end function;

    signal mem : mem_t := init_mem;

    constant CLK_PERIOD : time := 31250 ps;
    signal cycle_count : integer := 0;

    -- Observer state
    signal phase1_loop_count : integer := 0;  -- outer iterations (via DEC $32 count)
    signal inner_bne_count   : integer := 0;  -- $084A BNE seen
    signal outer_bne_count   : integer := 0;  -- $0850 BNE seen
    signal saw_phase2_entry  : std_logic := '0';
    signal y_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal saw_jmp_0100      : std_logic := '0';
    signal x_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal sp_at_phase2      : std_logic_vector(15 downto 0) := (others => '0');
    signal z32_at_phase2     : std_logic_vector(7 downto 0) := (others => '0');
    signal z32_min_seen      : std_logic_vector(7 downto 0) := x"FF";
    signal dest_hi_at_entry  : std_logic_vector(7 downto 0) := (others => '0');
    signal saw_phase2_copy_done : std_logic := '0';
    signal pc_prev           : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_prev          : std_logic_vector(7 downto 0) := (others => '0');

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
            DBG_X     => dbg_x,
            DBG_Y     => dbg_y,
            DBG_STATE => dbg_state
        );

    d_in <= mem(to_integer(unsigned(a_out(15 downto 0))));

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                mem(to_integer(unsigned(a_out(15 downto 0)))) <= d_out;
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

    obs_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                phase1_loop_count    <= 0;
                inner_bne_count      <= 0;
                outer_bne_count      <= 0;
                saw_phase2_entry     <= '0';
                saw_jmp_0100         <= '0';
                z32_min_seen         <= x"FF";
                saw_phase2_copy_done <= '0';
            elsif ce = '1' then
                pc_prev  <= dbg_pc;
                pbr_prev <= dbg_pbr;

                -- Count outer-loop iterations via DEC $32 at $0838
                -- (DBG_PC = opcode+1 so $0839 when DEC $32 is decoded).
                if dbg_pbr = x"00" and dbg_pc = x"0839" and dbg_ir = x"C6"
                   and pc_prev /= x"0839" then
                    phase1_loop_count <= phase1_loop_count + 1;
                end if;

                -- Track lowest $32 ever seen.
                if unsigned(mem(16#32#)) < unsigned(z32_min_seen) then
                    z32_min_seen <= mem(16#32#);
                end if;

                -- Inner BNE at $084A (DBG_PC=$084B while BNE decoded)
                if dbg_pbr = x"00" and dbg_pc = x"084B" and dbg_ir = x"D0"
                   and pc_prev /= x"084B" then
                    inner_bne_count <= inner_bne_count + 1;
                end if;

                -- Outer BNE at $0850 (DBG_PC=$0851)
                if dbg_pbr = x"00" and dbg_pc = x"0851" and dbg_ir = x"D0"
                   and pc_prev /= x"0851" then
                    outer_bne_count <= outer_bne_count + 1;
                end if;

                -- Phase-2 entry: first time PC = $0852 while IR = $B9 (LDA abs,Y).
                -- Require IR match to avoid transient pipeline artefacts.
                if dbg_pbr = x"00" and dbg_pc = x"0852" and dbg_ir = x"B9"
                   and saw_phase2_entry = '0' then
                    saw_phase2_entry <= '1';
                    y_at_phase2      <= dbg_y;
                    x_at_phase2      <= dbg_x;
                    sp_at_phase2     <= dbg_sp;
                    z32_at_phase2    <= mem(16#32#);
                    dest_hi_at_entry <= mem(16#0841#);
                end if;

                -- JMP $0100 reached (opcode $4C at $085B, DBG_PC=$085C)
                if dbg_pbr = x"00" and dbg_pc = x"085C" and dbg_ir = x"4C" then
                    saw_jmp_0100 <= '1';
                end if;
            end if;
        end if;
    end process;

    main_proc: process
        variable copy_ok : boolean := true;
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';

        -- Phase-1 is ~183 outer iters × 256 inner iters × ~20 cycles each
        -- ≈ 936,960 cycles. Allow 1.5M to be safe.
        wait for CLK_PERIOD * 1500000;

        report "================ ASTERIX PHASE-1 RESULT ================";
        report "Outer DEC $32 count (target 183): " & integer'image(phase1_loop_count);
        report "Inner BNE ($084A) count: " & integer'image(inner_bne_count);
        report "Outer BNE ($0850) count (target 182): " & integer'image(outer_bne_count);
        report "Lowest $32 seen: $" & to_hstring(z32_min_seen);
        report "Phase-2 entry (PC=$0852/IR=$B9) seen: " & std_logic'image(saw_phase2_entry)(2);
        report "Y at phase-2 entry = $" & to_hstring(y_at_phase2);
        report "X at phase-2 entry = $" & to_hstring(x_at_phase2);
        report "SP at phase-2 entry = $" & to_hstring(sp_at_phase2);
        report "$32 at phase-2 entry = $" & to_hstring(z32_at_phase2);
        report "$0841 (dest-hi) at phase-2 entry = $" & to_hstring(dest_hi_at_entry);
        report "JMP $0100 (PC=$085C) seen: " & std_logic'image(saw_jmp_0100)(2);

        -- Verify phase-2 payload copied to $0100-$01FF matches $0864-$0963
        if saw_jmp_0100 = '1' then
            copy_ok := true;
            for i in 0 to 255 loop
                if mem(16#0100# + i) /= std_logic_vector(to_unsigned(i, 8) xor x"A5") then
                    copy_ok := false;
                end if;
            end loop;
            if copy_ok then
                report "Phase-2 copy verified: $0100-$01FF matches source";
            else
                report "Phase-2 copy CORRUPT: $0100-$01FF does NOT match source" severity warning;
            end if;
        end if;

        if saw_phase2_entry = '1' and y_at_phase2 = x"0000" then
            report "PASS: Y=$00 at phase-2 entry (expected)";
        elsif saw_phase2_entry = '1' then
            report "FAIL: Y=$" & to_hstring(y_at_phase2)
                   & " at phase-2 entry (expected $00) -- bug REPRODUCES"
                   severity warning;
        else
            report "FAIL: phase-2 entry never reached -- phase-1 hung"
                   severity warning;
        end if;

        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
