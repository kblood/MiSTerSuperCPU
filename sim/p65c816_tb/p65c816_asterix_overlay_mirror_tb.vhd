-- p65c816_asterix_overlay_mirror_tb.vhd
--
-- 2026-04-25 hypothesis test: simulate scpu_rom_overlay-induced BRAM/SDRAM
-- divergence. With overlay='1' (status[82] feeds both supercpu_enable AND
-- scpu_rom_opt), bram_hit_native is suppressed for $8000-$FFFF, so reads in
-- that range come from buslogic→SDRAM. This bench models the failure mode
-- where SDRAM does NOT receive the relocator's writes (write-buffer drop or
-- timing race), by holding $C000-$FEFF in a separate `sdram` array
-- initialized to $FF and never updated.
--
-- CPU writes always update `mem` (BRAM proxy).
-- CPU reads:
--   * $0000-$7FFF or $D000-$DFFF -> `mem`
--   * $8000-$FFFF excl $D000-$DFFF -> `sdram` (overlay-active mode)
--
-- Reset vector + KERNAL stubs are still served from `mem` because the
-- relocator phase-1 writes them via STA — but if SDRAM-write-drop is real,
-- those would be unreadable. So we leave stubs in `sdram` as well.
--
-- Pass conditions:
--   * Reaches $CB00 -> overlay theory NOT confirmed (CPU got past despite
--     stale upper-half).
--   * Lands at PC=$C003 with c003_hits > 100 -> overlay theory CORROBORATED
--     in sim. Hardware-style hang reproduced.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

entity p65c816_asterix_overlay_mirror_tb is
end entity;

architecture sim of p65c816_asterix_overlay_mirror_tb is

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

    impure function load_asterix return mem_t is
        -- 2026-04-25 experiment: initialise $C000-$FEFF with $FF (matching the
        -- pattern hardware shows at PC=$C003 per uart_asterix_c003.log).
        -- If this reproduces the hang in sim, confirms "wrong-jump into
        -- uninitialised RAM" hypothesis.
        variable m : mem_t := (others => x"EA");
        file prg_file : text;
        variable L    : line;
        variable byte_val : integer;
        variable addr : integer;
        variable line_count : integer := 0;
    begin
        -- Pre-fill $C000-$FEFF with $FF (mimics uninitialized BRAM in
        -- hardware that wasn't overwritten by the asterix.prg load which
        -- only covers $0801-$BF93). Leave $FF00-$FFFF alone for KERNAL
        -- stubs / vectors to be set later.
        for a in 16#C000# to 16#FEFF# loop
            m(a) := x"FF";
        end loop;
        file_open(prg_file, "asterix.mem", read_mode);
        while not endfile(prg_file) loop
            readline(prg_file, L);
            read(L, addr);
            read(L, byte_val);
            if addr >= 0 and addr <= 65535 then
                m(addr) := std_logic_vector(to_unsigned(byte_val, 8));
            end if;
            line_count := line_count + 1;
        end loop;
        file_close(prg_file);
        report "Loaded " & integer'image(line_count) & " bytes from asterix.mem";

        -- Reset vector -> $0820 (phase-1 entry) + KERNAL stubs
        m(16#FFFC#) := x"20"; m(16#FFFD#) := x"08";
        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";
        m(16#FF00#) := x"40";  -- RTI for interrupts
        m(16#E5A0#) := x"60";  -- RTS stub
        m(16#A659#) := x"60";  -- RTS stub
        return m;
    end function;

    signal mem : mem_t := load_asterix;

    -- "SDRAM" image for upper half. Initialized to $FF for $C000-$FEFF
    -- (matching uninitialized DRAM hypothesis). Reset vectors and KERNAL
    -- stubs are pre-populated to mirror what the relocator writes to BRAM,
    -- so the CPU can still come out of reset.
    impure function init_sdram return mem_t is
        variable s : mem_t := (others => x"FF");
    begin
        -- Vectors / KERNAL stubs (so reset boot still works)
        s(16#FFFC#) := x"20"; s(16#FFFD#) := x"08";
        s(16#FFFE#) := x"00"; s(16#FFFF#) := x"FF";
        s(16#FF00#) := x"40";  -- RTI
        s(16#E5A0#) := x"60";  -- RTS
        s(16#A659#) := x"60";  -- RTS
        return s;
    end function;
    signal sdram : mem_t := init_sdram;

    constant CLK_PERIOD : time := 31250 ps;

    -- Observer state
    signal cli_seen          : std_logic := '0';
    signal cb00_seen         : std_logic := '0';
    signal saw_phase2_entry  : std_logic := '0';
    signal saw_jmp_0100      : std_logic := '0';
    signal y_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal x_at_phase2       : std_logic_vector(15 downto 0) := (others => '0');
    signal z2f_last          : std_logic_vector(7 downto 0) := (others => '0');
    signal z30_last          : std_logic_vector(7 downto 0) := (others => '0');
    signal pc_prev           : std_logic_vector(15 downto 0) := (others => '0');
    signal pbr_prev          : std_logic_vector(7 downto 0) := (others => '0');
    signal hit_0100_count    : integer := 0;
    signal hit_0197_count    : integer := 0;  -- exit path
    signal c003_hits         : integer := 0;  -- 2026-04-25: $C003 hang detector

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

    -- Read mux modeling scpu_rom_overlay='1' but TARGETED:
    -- The hardware UART shows hang at $C003 specifically. Hypothesis: most of
    -- the relocator's writes ($4800-$BFFF) DO land in SDRAM, but writes to
    -- the $C000+ range have a specific failure mode (e.g., a bus-arbitration
    -- corner case or page-table edge). Model that by routing only
    -- $C000-$FEFF reads to stale `sdram` (=$FF), all other addresses to `mem`.
    d_in <= x"60" when a_out(15 downto 0) = x"E5A0" or a_out(15 downto 0) = x"A659"
            else sdram(to_integer(unsigned(a_out(15 downto 0))))
                 when unsigned(a_out(15 downto 0)) >= x"C000"
                  and unsigned(a_out(15 downto 0)) <= x"FEFF"
            else mem(to_integer(unsigned(a_out(15 downto 0))));

    -- 2026-04-25 mirror variant: writes land in BOTH `mem` AND `sdram` so
    -- reads from the overlay-routed range return CORRECT data. If this bench
    -- still fails, BRAM-bypass alone (forcing reads through buslogic) is
    -- enough to break Asterix — meaning the bug is timing/latency in the
    -- buslogic path, not stale SDRAM data. If this bench PASSES, the bug is
    -- specifically about SDRAM having stale data (relocator's writes not
    -- persisting to SDRAM under hardware bus arbitration).
    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if ce = '1' and we_n = '0' then
                mem(to_integer(unsigned(a_out(15 downto 0)))) <= d_out;
                sdram(to_integer(unsigned(a_out(15 downto 0)))) <= d_out;
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

    obs: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cli_seen         <= '0';
                cb00_seen        <= '0';
                saw_phase2_entry <= '0';
                saw_jmp_0100     <= '0';
                hit_0100_count   <= 0;
                hit_0197_count   <= 0;
            elsif ce = '1' then
                pc_prev  <= dbg_pc;
                pbr_prev <= dbg_pbr;

                -- Phase-2 entry (first time PC=$0852, IR=$B9)
                if dbg_pbr = x"00" and dbg_pc = x"0852" and saw_phase2_entry = '0' then
                    saw_phase2_entry <= '1';
                    y_at_phase2      <= dbg_y;
                    x_at_phase2      <= dbg_x;
                end if;

                -- JMP $0100 reached
                if dbg_pbr = x"00" and dbg_pc = x"085C" then
                    saw_jmp_0100 <= '1';
                end if;

                -- Dispatcher entry at $0100 - count iterations
                if dbg_pbr = x"00" and dbg_pc = x"0101" and dbg_ir = x"B1"
                   and pc_prev /= x"0101" then
                    hit_0100_count <= hit_0100_count + 1;
                end if;

                -- Exit path ($0197 executed means handler 0 exit branch taken)
                if dbg_pbr = x"00" and dbg_pc = x"0198" and dbg_ir = x"2C"
                   and pc_prev /= x"0198" then
                    hit_0197_count <= hit_0197_count + 1;
                end if;

                -- CLI executed at $019E (IR=$58)
                if dbg_pbr = x"00" and dbg_pc = x"019F" and dbg_ir = x"58" then
                    cli_seen <= '1';
                end if;

                -- Game entry at $CB00
                if dbg_pbr = x"00" and dbg_pc = x"CB01" then
                    cb00_seen <= '1';
                end if;

                -- 2026-04-25: count $C003 hits (matches hardware hang locus)
                if dbg_pbr = x"00" and dbg_pc = x"C003" then
                    c003_hits <= c003_hits + 1;
                end if;

                -- Latch ZP src pointer on each read
                if we_n = '1' and a_out(15 downto 0) = x"002F" then
                    z2f_last <= d_in;
                end if;
                if we_n = '1' and a_out(15 downto 0) = x"0030" then
                    z30_last <= d_in;
                end if;
            end if;
        end if;
    end process;

    reset_proc: process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 8;
        rst_n <= '1';
        wait;
    end process;

    -- PC trace dumper. Emits one line per fetched instruction in the
    -- format documented in tools/vice_diff/trace_format.md:
    --     <seq>:<pbr>:<pc>:<ir>:<p>:<sp>
    -- Trigger: VPA='1' AND VDA='1' (opcode fetch) on a NEW PC.
    --
    -- Tracing is GATED by trace_armed: it does not start until phase-1
    -- copy loops complete (PC first reaches $0852, the phase-2 entry).
    -- This avoids burning the entry budget on the deterministic relocator
    -- (~6 M instructions of which the dispatcher diff doesn't care).
    trace_proc: process(clk)
        file trace_file : text;
        variable L              : line;
        variable opened         : boolean := false;
        variable trace_armed    : boolean := false;
        variable seq            : integer := 0;
        variable pc_t_prev      : std_logic_vector(15 downto 0) := (others => '1');
        variable pbr_t_prev     : std_logic_vector(7 downto 0)  := (others => '1');
        constant TRACE_MAX_ENTRIES : integer := 500000;
    begin
        if rising_edge(clk) then
            if not opened then
                file_open(trace_file, "ours_trace.txt", write_mode);
                write(L, string'("TRACE_START"));
                writeline(trace_file, L);
                opened := true;
            end if;

            if rst_n = '1' and ce = '1' and vpa = '1' and vda = '1' then
                -- Arm the trace at phase-2 entry (PC=$0852, PBR=$00)
                if not trace_armed and dbg_pbr = x"00" and dbg_pc = x"0852" then
                    trace_armed := true;
                    write(L, string'("# trace armed at phase-2 entry"));
                    writeline(trace_file, L);
                end if;

                if trace_armed and seq < TRACE_MAX_ENTRIES
                   and (dbg_pc /= pc_t_prev or dbg_pbr /= pbr_t_prev) then
                    write(L, integer'image(seq));
                    write(L, string'(":"));
                    write(L, to_hstring(dbg_pbr));
                    write(L, string'(":"));
                    write(L, to_hstring(dbg_pc));
                    write(L, string'(":"));
                    write(L, to_hstring(dbg_ir));
                    write(L, string'(":"));
                    write(L, to_hstring(dbg_p));
                    write(L, string'(":"));
                    write(L, to_hstring(dbg_sp));
                    writeline(trace_file, L);
                    seq        := seq + 1;
                    pc_t_prev  := dbg_pc;
                    pbr_t_prev := dbg_pbr;
                end if;
            end if;

            if seq = TRACE_MAX_ENTRIES then
                write(L, string'("TRACE_TRUNCATED"));
                writeline(trace_file, L);
                seq := seq + 1;  -- prevent re-emit
            end if;
        end if;
    end process;

    timeout_proc: process
    begin
        wait for CLK_PERIOD * 10000000;  -- 312 ms sim
        report "================ ASTERIX FULL RESULT ================";
        report "Phase-2 entry seen: " & std_logic'image(saw_phase2_entry)(2);
        report "  Y at phase-2: $" & to_hstring(y_at_phase2);
        report "  X at phase-2: $" & to_hstring(x_at_phase2);
        report "JMP $0100 seen: " & std_logic'image(saw_jmp_0100)(2);
        report "Dispatcher iterations ($0100 hits): " & integer'image(hit_0100_count);
        report "Handler-0 exit path ($0197 hits): " & integer'image(hit_0197_count);
        report "CLI executed: " & std_logic'image(cli_seen)(2);
        report "$CB00 reached: " & std_logic'image(cb00_seen)(2);
        report "Last ZP $2F/$30 = $" & to_hstring(z30_last) & to_hstring(z2f_last);
        report "$C003 hits: " & integer'image(c003_hits);

        if cb00_seen = '1' then
            report "PASS: full Asterix prelude completes on bare CPU";
        elsif saw_jmp_0100 = '1' and hit_0100_count > 100 then
            report "FAIL: dispatcher loops without terminating -- bug REPRODUCES on bare CPU"
                severity warning;
        elsif saw_jmp_0100 = '1' then
            report "PARTIAL: dispatcher entered but budget insufficient"
                severity warning;
        else
            report "EARLIER FAIL: did not reach dispatcher"
                severity warning;
        end if;
        report "================ DONE ================";
        std.env.finish;
    end process;

end architecture;
