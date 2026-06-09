-- p65c816_sst_tb.vhd
--
-- SingleStepTests/65816 (https://github.com/SingleStepTests/65816) GHDL
-- harness for the P65C816 RTL. Reads a converter-produced text record
-- file (see tools/sst_convert.py) and runs each case end-to-end:
--
--   1. Memory cleared, prelude bytecode + initial RAM written, reset
--      vector $00:FFFC/D pointed at $00:FE00 (prelude entry).
--   2. CPU reset for 8 cycles. Released; prelude runs (CLC/XCE/REP/
--      SEP/LDA/PHA/PLB/LDX/TXS/LDA/LDX/LDY/SEP/LDA/PHA/PLP/(SEC/XCE)/
--      JML pbr:pc) -- CPU lands on case.initial.pbr:pc fully primed.
--   3. Bench arms when (DBG_PBR, DBG_PC) == (case.pbr, case.pc) on a
--      VPA+VDA opcode-fetch cycle. From there it records exactly
--      `len(case.cycles)` consecutive clock cycles into a per-case
--      observed array.
--   4. After the test instruction completes, bench compares:
--        * final registers  (DBG_PC/SP/P/X/Y/D/DBR/PBR + EF_OUT)
--        * final RAM cells  (only addresses listed in FR -- others
--                           untouched per SST semantics)
--        * cycle list       (addr / RWB / VDA / VPA / MLB; data only
--                           when valid)
--      Mismatches log a `FAIL: case <N> <reason>` line; matches log
--      `PASS: case <N>` (or summary-only when verbose=false).
--
-- Phase 1 scope: works for the 28 RMW opcodes (04/0C/14/1C TSB/TRB and
-- 24 ASL/LSR/ROL/ROR/INC/DEC variants). These don't mutate A, so DBG_A
-- isn't required for register comparison. Phase 2 (full 256-opcode
-- sweep) needs DBG_A wired through P65C816 to also verify A/B updates.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

use work.sst_mem_pkg.all;

entity p65c816_sst_tb is
    generic (
        input_file : string  := "../../external/65816/v1.bin/06.e.txt";
        max_cases  : integer := 0;          -- 0 = run all in file
        verbose    : boolean := false;
        prelude_base_lo : integer := 16#FE00#;  -- $00:FE00 prelude entry
        -- When true, drive D_IN with a garbage constant on every INTERNAL
        -- cycle (VDA=0 and VPA=0). Proves the CPU never depends on the data
        -- bus during internal cycles -- the precondition for an internal-cycle
        -- fast-fire speed lever (advance the CPU on internal cycles without a
        -- real SDRAM read). If SST stays 0-fail with this on, it is safe.
        garbage_internal : boolean := false
    );
end entity;

architecture sim of p65c816_sst_tb is

    -- DUT signals
    signal clk     : std_logic := '0';
    signal rst_n   : std_logic := '0';
    signal ce      : std_logic := '1';
    signal d_in    : std_logic_vector(7 downto 0) := (others => '0');
    signal d_out   : std_logic_vector(7 downto 0);
    signal a_out   : std_logic_vector(23 downto 0);
    signal we_n    : std_logic;
    signal vpa_s   : std_logic;
    signal vda_s   : std_logic;
    signal mlb_s   : std_logic;
    signal vpb_s   : std_logic;
    signal ef_out  : std_logic;
    signal rdy_out : std_logic;

    signal dbg_pc    : std_logic_vector(15 downto 0);
    signal dbg_sp    : std_logic_vector(15 downto 0);
    signal dbg_p     : std_logic_vector(7 downto 0);
    signal dbg_ir    : std_logic_vector(7 downto 0);
    signal dbg_pbr   : std_logic_vector(7 downto 0);
    signal dbg_dbr   : std_logic_vector(7 downto 0);
    signal dbg_x     : std_logic_vector(15 downto 0);
    signal dbg_y     : std_logic_vector(15 downto 0);
    signal dbg_d     : std_logic_vector(15 downto 0);
    signal dbg_a     : std_logic_vector(15 downto 0);
    signal dbg_state : std_logic_vector(3 downto 0);

    constant CLK_PERIOD : time := 31250 ps;  -- 32 MHz

    -- Sparse 24-bit memory (lazy bank allocation)
    shared variable mem : sst_mem_t;

begin
    -----------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------
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
            VPA       => vpa_s,
            VDA       => vda_s,
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
            DBG_D     => dbg_d,
            DBG_A     => dbg_a,
            DBG_STATE => dbg_state
        );

    -----------------------------------------------------------------------------
    -- Combinational memory read for D_IN
    --
    -- garbage_internal: on internal cycles (VDA=0 and VPA=0) the W65C816 makes
    -- no valid memory access, so the data bus is don't-care. When the generic
    -- is set, force D_IN to a garbage constant on those cycles to PROVE the
    -- datapath never consumes it (internal-cycle fast-fire safety proof).
    -----------------------------------------------------------------------------
    d_in <= x"5A" when (garbage_internal and vda_s = '0' and vpa_s = '0')
            else mem.read24(unsigned(a_out));

    -----------------------------------------------------------------------------
    -- Memory write process
    -----------------------------------------------------------------------------
    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '1' and ce = '1' and we_n = '0' then
                mem.write24(unsigned(a_out), d_out);
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    -----------------------------------------------------------------------------
    -- Main case-loop process
    -----------------------------------------------------------------------------
    main_proc: process

        -- Local helpers ----------------------------------------------------------
        function hex_to_int(s : string) return integer is
            variable r : integer := 0;
            variable c : character;
        begin
            for i in s'range loop
                c := s(i);
                r := r * 16;
                case c is
                    when '0' to '9' => r := r + (character'pos(c) - character'pos('0'));
                    when 'A' to 'F' => r := r + 10 + (character'pos(c) - character'pos('A'));
                    when 'a' to 'f' => r := r + 10 + (character'pos(c) - character'pos('a'));
                    when others     => null;
                end case;
            end loop;
            return r;
        end function;

        function slv(val, width : integer) return std_logic_vector is
        begin
            return std_logic_vector(to_unsigned(val, width));
        end function;

        function hex_str(v : integer; width : integer) return string is
            constant hex_chars : string(1 to 16) := "0123456789ABCDEF";
            variable r : string(1 to width);
            variable t : integer := v;
        begin
            for i in width downto 1 loop
                r(i) := hex_chars((t mod 16) + 1);
                t := t / 16;
            end loop;
            return r;
        end function;

        function slv_to_hex(v : std_logic_vector) return string is
            variable u : unsigned(v'length - 1 downto 0);
        begin
            u := unsigned(v);
            return hex_str(to_integer(u), v'length / 4);
        end function;

        function flag_at(s : string; idx : integer; ch : character) return std_logic is
        begin
            if s(s'low + idx) = ch then
                return '1';
            else
                return '0';
            end if;
        end function;

        -- Skip leading whitespace on a line
        procedure skip_ws(variable l : inout line) is
            variable c : character;
        begin
            while l /= null and l'length > 0 loop
                exit when l.all(l.all'low) /= ' ' and l.all(l.all'low) /= HT;
                read(l, c);
            end loop;
        end procedure;

        -- Read next whitespace-delimited token into a string buffer
        procedure read_tok(variable l : inout line;
                           variable tok : out string;
                           variable tok_len : out natural) is
            variable c : character;
            variable n : natural := 0;
        begin
            skip_ws(l);
            tok_len := 0;
            while l /= null and l'length > 0 loop
                exit when l.all(l.all'low) = ' ' or l.all(l.all'low) = HT;
                if n < tok'length then
                    n := n + 1;
                    read(l, c);
                    tok(tok'low + n - 1) := c;
                else
                    exit;
                end if;
            end loop;
            tok_len := n;
        end procedure;

        -- Read an unsigned hex token (skips whitespace)
        procedure read_hex(variable l : inout line; variable val : out integer) is
            variable tok : string(1 to 8);
            variable tok_len : natural;
        begin
            read_tok(l, tok, tok_len);
            val := hex_to_int(tok(1 to tok_len));
        end procedure;

        -- Read a decimal integer token (skips whitespace)
        procedure read_dec(variable l : inout line; variable val : out integer) is
            variable tok : string(1 to 8);
            variable tok_len : natural;
            variable r : integer := 0;
        begin
            read_tok(l, tok, tok_len);
            for i in 1 to tok_len loop
                r := r * 10 + (character'pos(tok(i)) - character'pos('0'));
            end loop;
            val := r;
        end procedure;

        -- Read N tokens of any kind into discard
        procedure read_eat_tag(variable l : inout line) is
            variable tok : string(1 to 4);
            variable tok_len : natural;
        begin
            read_tok(l, tok, tok_len);  -- discard tag e.g. "C", "I", "PRE"
        end procedure;

        -- File state
        file     fin       : text;
        variable l         : line;
        variable n_cases   : integer := 0;
        variable case_idx  : integer := 0;

        -- Per-case data
        variable init_pc, init_s, init_a, init_x, init_y, init_d : integer;
        variable init_p, init_dbr, init_pbr, init_e              : integer;
        variable fin_pc, fin_s, fin_a, fin_x, fin_y, fin_d       : integer;
        variable fin_p, fin_dbr, fin_pbr, fin_e                  : integer;

        variable n_pre, n_ir, n_fr, n_cy : integer;
        type byte_arr_t is array (0 to 63) of std_logic_vector(7 downto 0);
        variable pre_bytes : byte_arr_t;

        type addr_val_t is record
            addr : unsigned(23 downto 0);
            val  : std_logic_vector(7 downto 0);
        end record;
        type av_arr_t is array (0 to 63) of addr_val_t;
        variable ir_cells : av_arr_t;
        variable fr_cells : av_arr_t;

        type cyc_exp_t is record
            addr  : unsigned(23 downto 0);
            data  : std_logic_vector(7 downto 0);
            valid : std_logic;
            d_f   : std_logic;
            p_f   : std_logic;
            v_f   : std_logic;
            r_f   : std_logic;  -- '1' for read, '0' for write
            e_f   : std_logic;
            m_f   : std_logic;
            x_f   : std_logic;
            l_f   : std_logic;
        end record;
        type cyc_arr_t is array (0 to 127) of cyc_exp_t;
        variable cyc_exp : cyc_arr_t;

        type cyc_obs_t is record
            addr  : std_logic_vector(23 downto 0);
            data  : std_logic_vector(7 downto 0);
            we    : std_logic;
            vda   : std_logic;
            vpa   : std_logic;
            vpb   : std_logic;
            mlb   : std_logic;
            ef    : std_logic;
            mf    : std_logic;
            xf    : std_logic;
        end record;
        type cyc_obs_arr_t is array (0 to 127) of cyc_obs_t;
        variable observed : cyc_obs_arr_t;

        -- Counters
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable skip_count : integer := 0;
        variable case_failed : boolean;
        variable case_skipped : boolean;
        variable fail_reason : line;

        -- Local vars
        variable tmp_addr  : integer;
        variable tmp_val   : integer;
        variable tmp_int   : integer;
        variable val_tok   : string(1 to 8);
        variable val_len   : natural;
        variable flag_tok  : string(1 to 8);
        variable flag_len  : natural;

        variable armed     : boolean;
        variable cyc_idx   : integer;
        variable cycles_settle : integer;

        variable stk_top    : integer;
        variable stk_below  : integer;

        variable target_pbr : std_logic_vector(7 downto 0);
        variable target_pc  : std_logic_vector(15 downto 0);

        -- Final-state snapshot, captured during the LAST recorded cycle so
        -- DBG_PC etc. reflect the state at the end of the test instruction
        -- (one rising edge later, the CPU has already begun the next
        -- opcode fetch and advanced PC).
        variable cap_pc  : std_logic_vector(15 downto 0);
        variable cap_sp  : std_logic_vector(15 downto 0);
        variable cap_p   : std_logic_vector(7 downto 0);
        variable cap_x   : std_logic_vector(15 downto 0);
        variable cap_y   : std_logic_vector(15 downto 0);
        variable cap_d   : std_logic_vector(15 downto 0);
        variable cap_a   : std_logic_vector(15 downto 0);
        variable cap_pbr : std_logic_vector(7 downto 0);
        variable cap_dbr : std_logic_vector(7 downto 0);
        variable cap_ef  : std_logic;

    begin
        report "================ SST HARNESS START ================";
        report "input_file  = " & input_file;
        report "max_cases   = " & integer'image(max_cases);

        file_open(fin, input_file, read_mode);

        -- Header line: "H <opcode:2> <mode:1> <n_cases>"
        readline(fin, l);
        read_eat_tag(l);                  -- 'H'
        read_hex(l, tmp_int);             -- opcode (discard)
        read_eat_tag(l);                  -- mode 'e' or 'n'
        read_dec(l, n_cases);
        report "n_cases=" & integer'image(n_cases);

        if max_cases > 0 and max_cases < n_cases then
            n_cases := max_cases;
        end if;

        -- Initial reset hold
        rst_n <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        -----------------------------------------------------------------------
        -- Per-case loop
        -----------------------------------------------------------------------
        for case_idx_loop in 0 to n_cases - 1 loop
            case_idx := case_idx_loop;
            case_failed := false;
            case_skipped := false;

            -- "C <idx>"
            readline(fin, l);
            read_eat_tag(l);
            read_dec(l, tmp_int);
            assert tmp_int = case_idx
                report "case-index mismatch: expected " & integer'image(case_idx) &
                       " got " & integer'image(tmp_int) severity failure;

            -- "I <pc> <s> <p> <a> <x> <y> <d> <dbr> <pbr> <e>"
            readline(fin, l);
            read_eat_tag(l);
            read_hex(l, init_pc);
            read_hex(l, init_s);
            read_hex(l, init_p);
            read_hex(l, init_a);
            read_hex(l, init_x);
            read_hex(l, init_y);
            read_hex(l, init_d);
            read_hex(l, init_dbr);
            read_hex(l, init_pbr);
            read_hex(l, init_e);

            -- "PRE <n>"
            readline(fin, l);
            read_eat_tag(l);
            read_dec(l, n_pre);

            -- bytes line
            readline(fin, l);
            for i in 0 to n_pre - 1 loop
                read_hex(l, tmp_val);
                pre_bytes(i) := slv(tmp_val, 8);
            end loop;

            -- "IR <n>"
            readline(fin, l);
            read_eat_tag(l);
            read_dec(l, n_ir);
            for i in 0 to n_ir - 1 loop
                readline(fin, l);
                read_hex(l, tmp_addr);
                read_hex(l, tmp_val);
                ir_cells(i).addr := to_unsigned(tmp_addr, 24);
                ir_cells(i).val  := slv(tmp_val, 8);
            end loop;

            -- "F ..."
            readline(fin, l);
            read_eat_tag(l);
            read_hex(l, fin_pc);
            read_hex(l, fin_s);
            read_hex(l, fin_p);
            read_hex(l, fin_a);
            read_hex(l, fin_x);
            read_hex(l, fin_y);
            read_hex(l, fin_d);
            read_hex(l, fin_dbr);
            read_hex(l, fin_pbr);
            read_hex(l, fin_e);

            -- "FR <n>"
            readline(fin, l);
            read_eat_tag(l);
            read_dec(l, n_fr);
            for i in 0 to n_fr - 1 loop
                readline(fin, l);
                read_hex(l, tmp_addr);
                read_hex(l, tmp_val);
                fr_cells(i).addr := to_unsigned(tmp_addr, 24);
                fr_cells(i).val  := slv(tmp_val, 8);
            end loop;

            -- "CY <n>"
            readline(fin, l);
            read_eat_tag(l);
            read_dec(l, n_cy);
            assert n_cy <= 127 report "cycle count exceeds buffer (>127)" severity failure;
            for i in 0 to n_cy - 1 loop
                readline(fin, l);
                read_hex(l, tmp_addr);
                read_tok(l, val_tok, val_len);   -- "XX" or hex
                read_dec(l, tmp_int);            -- valid 0/1
                read_tok(l, flag_tok, flag_len); -- 8-char flag string
                cyc_exp(i).addr  := to_unsigned(tmp_addr, 24);
                if val_tok(1 to val_len) = "XX" or val_tok(1 to val_len) = "xx" then
                    cyc_exp(i).valid := '0';
                    cyc_exp(i).data  := (others => '-');
                else
                    cyc_exp(i).valid := '1';
                    cyc_exp(i).data  := slv(hex_to_int(val_tok(1 to val_len)), 8);
                end if;
                cyc_exp(i).d_f := flag_at(flag_tok(1 to flag_len), 0, 'd');
                cyc_exp(i).p_f := flag_at(flag_tok(1 to flag_len), 1, 'p');
                cyc_exp(i).v_f := flag_at(flag_tok(1 to flag_len), 2, 'v');
                cyc_exp(i).r_f := flag_at(flag_tok(1 to flag_len), 3, 'r');
                cyc_exp(i).e_f := flag_at(flag_tok(1 to flag_len), 4, 'e');
                cyc_exp(i).m_f := flag_at(flag_tok(1 to flag_len), 5, 'm');
                cyc_exp(i).x_f := flag_at(flag_tok(1 to flag_len), 6, 'x');
                cyc_exp(i).l_f := flag_at(flag_tok(1 to flag_len), 7, 'l');
            end loop;

            -- "E"
            readline(fin, l);

            -------------------------------------------------------------------
            -- Set up memory: clear, write prelude, init RAM, reset vector
            -------------------------------------------------------------------
            -- Detect prelude/case-data collision. If any init.ram OR
            -- final.ram cell lives inside $00:FE00..FE00+n_pre-1 (where
            -- the prelude lives), running this case would either crash
            -- the prelude (IR overwrites it) or read the wrong test
            -- value (prelude overwrites IR). Phase 0/1 skip these.
            -- ALSO skip cases where ram cells live at the two stack bytes
            -- the prelude transiently uses for the PHA/PLA save/restore
            -- around LDA #p in step 10. Stack address is bank 0:
            --   * emu (init_e=1):    $00:01:S_lo and $00:01:(S_lo-1)
            --   * native (init_e=0): $00:S      and $00:(S-1)
            for i in 0 to n_ir - 1 loop
                if ir_cells(i).addr(23 downto 16) = x"00" and
                   to_integer(ir_cells(i).addr(15 downto 0)) >= prelude_base_lo and
                   to_integer(ir_cells(i).addr(15 downto 0)) < prelude_base_lo + n_pre
                then
                    case_skipped := true;
                end if;
            end loop;
            for i in 0 to n_fr - 1 loop
                if fr_cells(i).addr(23 downto 16) = x"00" and
                   to_integer(fr_cells(i).addr(15 downto 0)) >= prelude_base_lo and
                   to_integer(fr_cells(i).addr(15 downto 0)) < prelude_base_lo + n_pre
                then
                    case_skipped := true;
                end if;
            end loop;
            -- Reset-stub stack collision: the RTL's reset-interrupt
            -- microcode runs through the standard 3-push BRK sequence
            -- (suppressing the actual writes via BUS_CTRL but still
            -- decrementing SP), leaving SP=$01:FD by the time the
            -- prelude's first instruction fetches. The prelude's
            -- first PHA (offset 12 of the prelude, in native mode
            -- after the first XCE) writes to $00:01:FD to feed PLB.
            -- That clobbers any case init.ram cell at $00:01:FD.
            for i in 0 to n_ir - 1 loop
                if ir_cells(i).addr(23 downto 16) = x"00" and
                   to_integer(ir_cells(i).addr(15 downto 0)) = 16#01FD#
                then
                    case_skipped := true;
                end if;
            end loop;
            -- Reset-vector collision: bench writes $00:FFFC/D last so the
            -- prelude can boot, which clobbers any case init.ram cell at
            -- those addresses. Skip cases that read or write those bytes.
            for i in 0 to n_ir - 1 loop
                if ir_cells(i).addr(23 downto 16) = x"00" and
                   (to_integer(ir_cells(i).addr(15 downto 0)) = 16#FFFC# or
                    to_integer(ir_cells(i).addr(15 downto 0)) = 16#FFFD#)
                then
                    case_skipped := true;
                end if;
            end loop;
            for i in 0 to n_fr - 1 loop
                if fr_cells(i).addr(23 downto 16) = x"00" and
                   (to_integer(fr_cells(i).addr(15 downto 0)) = 16#FFFC# or
                    to_integer(fr_cells(i).addr(15 downto 0)) = 16#FFFD#)
                then
                    case_skipped := true;
                end if;
            end loop;
            -- Stack-collision skip: prelude PHA in step 10 transiently
            -- writes to one stack byte ($01:S_lo for emu, $00:S for native).
            -- If the case lists that address as test RAM, the case value
            -- is clobbered. Two addresses kept (over-conservative) for
            -- safety against future prelude tweaks that touch a 2nd byte.
            -- ALSO: in native mode, if init_s points INTO the prelude byte
            -- range $00:FE00..FE00+n_pre, PHA self-corrupts the prelude
            -- and the JML never fires (ARM timeout). Skip those too.
            if init_e = 1 then
                stk_top   := 16#100# + (init_s mod 256);
                stk_below := 16#100# + ((init_s - 1) mod 256);
            else
                stk_top   := init_s mod 65536;
                stk_below := (init_s - 1) mod 65536;
                if stk_top  >= prelude_base_lo and stk_top  < prelude_base_lo + n_pre then
                    case_skipped := true;
                end if;
                if stk_below >= prelude_base_lo and stk_below < prelude_base_lo + n_pre then
                    case_skipped := true;
                end if;
            end if;
            for i in 0 to n_ir - 1 loop
                if ir_cells(i).addr(23 downto 16) = x"00" and
                   (to_integer(ir_cells(i).addr(15 downto 0)) = stk_top or
                    to_integer(ir_cells(i).addr(15 downto 0)) = stk_below)
                then
                    case_skipped := true;
                end if;
            end loop;
            -- F10 (2026-05-03): the previous "skip if FR cell sits at the
            -- prelude's transient PHA stack byte" check was over-conservative.
            -- An FR cell at the stack address means SST recorded a CHANGED
            -- final value, which by definition implies the test instruction
            -- wrote there. The prelude's stale $BF at stk_top is overwritten
            -- by that legitimate stack push, so the final state matches.
            -- The IR-cell loop above remains the real safety net (init.ram
            -- collisions where the prelude clobbers test setup).
            -- Without this fix, $FC JSR (abs,X) and similar stack-pushing
            -- ops at SP=stk_top skipped 100 % of cases.

            mem.clear_all;
            -- IR cells first, prelude second, so prelude bytes override any
            -- collision (case may happen to have an init.ram cell in the
            -- $00:FE00-FE28 prelude range; prelude must remain intact).
            for i in 0 to n_ir - 1 loop
                mem.write24(ir_cells(i).addr, ir_cells(i).val);
            end loop;
            for i in 0 to n_pre - 1 loop
                mem.write24(to_unsigned(prelude_base_lo + i, 24), pre_bytes(i));
            end loop;
            -- Reset vector $00:FFFC/D -> $00:FE00 (prelude entry)
            mem.write24(to_unsigned(16#FFFC#, 24), slv(prelude_base_lo mod 256, 8));
            mem.write24(to_unsigned(16#FFFD#, 24), slv(prelude_base_lo / 256, 8));

            -- Skip collision cases without running CPU
            if case_skipped then
                skip_count := skip_count + 1;
                if verbose then
                    write(l, string'("SKIP case ")); write(l, case_idx);
                    write(l, string'(" (prelude/IR collision)"));
                    writeline(output, l);
                end if;
                next;
            end if;

            -------------------------------------------------------------------
            -- Reset CPU
            -------------------------------------------------------------------
            rst_n <= '0';
            for i in 1 to 8 loop
                wait until rising_edge(clk);
            end loop;
            rst_n <= '1';

            -------------------------------------------------------------------
            -- Wait for armed condition: VPA+VDA opcode fetch at case PBR:PC
            -------------------------------------------------------------------
            target_pbr := slv(init_pbr, 8);
            target_pc  := slv(init_pc, 16);
            armed := false;
            cycles_settle := 0;

            while not armed loop
                wait until rising_edge(clk);
                cycles_settle := cycles_settle + 1;
                if verbose and vpa_s = '1' and vda_s = '1' and we_n = '1' then
                    write(l, string'("  PRELUDE @c=")); write(l, cycles_settle);
                    write(l, string'(" pc=")); write(l, slv_to_hex(dbg_pbr));
                    write(l, string'(":")); write(l, slv_to_hex(dbg_pc));
                    write(l, string'(" P=")); write(l, slv_to_hex(dbg_p));
                    write(l, string'(" D=")); write(l, slv_to_hex(dbg_d));
                    write(l, string'(" S=")); write(l, slv_to_hex(dbg_sp));
                    write(l, string'(" DBR=")); write(l, slv_to_hex(dbg_dbr));
                    write(l, string'(" E=")); write(l, std_logic'image(ef_out)(2 to 2));
                    write(l, string'(" IR=")); write(l, slv_to_hex(d_in));
                    writeline(output, l);
                end if;
                if cycles_settle > 400 then
                    write(fail_reason, string'("ARM timeout: PRELUDE never landed at "));
                    write(fail_reason, slv_to_hex(target_pbr));
                    write(fail_reason, string'(":"));
                    write(fail_reason, slv_to_hex(target_pc));
                    case_failed := true;
                    exit;
                end if;
                if vpa_s = '1' and vda_s = '1' and we_n = '1' and
                   a_out(23 downto 16) = target_pbr and
                   a_out(15 downto 0) = target_pc and
                   cycles_settle > 30
                then
                    armed := true;
                end if;
            end loop;

            -------------------------------------------------------------------
            -- Record cycles
            -------------------------------------------------------------------
            if not case_failed then
                cyc_idx := 0;
                while cyc_idx < n_cy loop
                    observed(cyc_idx).addr := a_out;
                    if we_n = '0' then
                        observed(cyc_idx).data := d_out;
                    else
                        observed(cyc_idx).data := d_in;
                    end if;
                    observed(cyc_idx).we   := we_n;
                    observed(cyc_idx).vda  := vda_s;
                    observed(cyc_idx).vpa  := vpa_s;
                    observed(cyc_idx).vpb  := vpb_s;
                    observed(cyc_idx).mlb  := not mlb_s;  -- RTL active-low; SST reports as 1=locked
                    observed(cyc_idx).ef   := ef_out;
                    observed(cyc_idx).mf   := dbg_p(5);
                    observed(cyc_idx).xf   := dbg_p(4);
                    cyc_idx := cyc_idx + 1;
                    wait until rising_edge(clk);
                end loop;
                -- Capture final state ONE clock AFTER the last recorded
                -- cycle. The last SST cycle is always either an operand
                -- fetch or a memory access; the CPU still has to advance
                -- PC and commit the next-state register file on the
                -- following edge. Capturing inside the loop reads the
                -- pre-commit state and produces a PC off-by-one.
                cap_pc  := dbg_pc;
                cap_sp  := dbg_sp;
                cap_p   := dbg_p;
                cap_x   := dbg_x;
                cap_y   := dbg_y;
                cap_d   := dbg_d;
                cap_a   := dbg_a;
                cap_pbr := dbg_pbr;
                cap_dbr := dbg_dbr;
                cap_ef  := ef_out;

                -------------------------------------------------------------------
                -- COMPARE
                -------------------------------------------------------------------
                if cap_pbr /= slv(fin_pbr, 8) or cap_pc /= slv(fin_pc, 16) then
                    write(fail_reason, string'("PBR:PC exp="));
                    write(fail_reason, hex_str(fin_pbr, 2));
                    write(fail_reason, string'(":"));
                    write(fail_reason, hex_str(fin_pc, 4));
                    write(fail_reason, string'(" got="));
                    write(fail_reason, slv_to_hex(cap_pbr));
                    write(fail_reason, string'(":"));
                    write(fail_reason, slv_to_hex(cap_pc));
                    case_failed := true;
                end if;

                if not case_failed then
                    if init_e = 1 then
                        if cap_sp(7 downto 0) /= slv(fin_s mod 256, 8) then
                            write(fail_reason, string'("SPL exp="));
                            write(fail_reason, hex_str(fin_s mod 256, 2));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_sp(7 downto 0)));
                            case_failed := true;
                        end if;
                    else
                        if cap_sp /= slv(fin_s, 16) then
                            write(fail_reason, string'("SP exp="));
                            write(fail_reason, hex_str(fin_s, 4));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_sp));
                            case_failed := true;
                        end if;
                    end if;
                end if;

                if not case_failed and cap_p /= slv(fin_p, 8) then
                    write(fail_reason, string'("P exp="));
                    write(fail_reason, hex_str(fin_p, 2));
                    write(fail_reason, string'(" got="));
                    write(fail_reason, slv_to_hex(cap_p));
                    case_failed := true;
                end if;

                if not case_failed then
                    if init_e = 1 or ((init_p / 16) mod 2 = 1) then
                        if cap_x(7 downto 0) /= slv(fin_x mod 256, 8) then
                            write(fail_reason, string'("X8 exp="));
                            write(fail_reason, hex_str(fin_x mod 256, 2));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_x(7 downto 0)));
                            case_failed := true;
                        elsif cap_y(7 downto 0) /= slv(fin_y mod 256, 8) then
                            write(fail_reason, string'("Y8 exp="));
                            write(fail_reason, hex_str(fin_y mod 256, 2));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_y(7 downto 0)));
                            case_failed := true;
                        end if;
                    else
                        if cap_x /= slv(fin_x, 16) then
                            write(fail_reason, string'("X16 exp="));
                            write(fail_reason, hex_str(fin_x, 4));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_x));
                            case_failed := true;
                        elsif cap_y /= slv(fin_y, 16) then
                            write(fail_reason, string'("Y16 exp="));
                            write(fail_reason, hex_str(fin_y, 4));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(cap_y));
                            case_failed := true;
                        end if;
                    end if;
                end if;

                if not case_failed and cap_d /= slv(fin_d, 16) then
                    write(fail_reason, string'("D exp="));
                    write(fail_reason, hex_str(fin_d, 4));
                    write(fail_reason, string'(" got="));
                    write(fail_reason, slv_to_hex(cap_d));
                    case_failed := true;
                end if;

                -- A register: SST reports the full 16-bit C, which is
                -- correct regardless of M flag (M=1 8-bit mode preserves
                -- B in the high byte, and SEP/REP M transitions don't
                -- destroy the unused half). A 16-bit compare is therefore
                -- always correct.
                if not case_failed and cap_a /= slv(fin_a, 16) then
                    write(fail_reason, string'("A exp="));
                    write(fail_reason, hex_str(fin_a, 4));
                    write(fail_reason, string'(" got="));
                    write(fail_reason, slv_to_hex(cap_a));
                    case_failed := true;
                end if;

                if not case_failed and cap_dbr /= slv(fin_dbr, 8) then
                    write(fail_reason, string'("DBR exp="));
                    write(fail_reason, hex_str(fin_dbr, 2));
                    write(fail_reason, string'(" got="));
                    write(fail_reason, slv_to_hex(cap_dbr));
                    case_failed := true;
                end if;

                if not case_failed then
                    if (cap_ef = '1' and fin_e /= 1) or (cap_ef = '0' and fin_e /= 0) then
                        write(fail_reason, string'("E exp="));
                        write(fail_reason, integer'image(fin_e));
                        case_failed := true;
                    end if;
                end if;

                -- Final RAM cells
                for i in 0 to n_fr - 1 loop
                    if not case_failed and mem.read24(fr_cells(i).addr) /= fr_cells(i).val then
                        write(fail_reason, string'("RAM["));
                        write(fail_reason, hex_str(to_integer(fr_cells(i).addr), 6));
                        write(fail_reason, string'("] exp="));
                        write(fail_reason, slv_to_hex(fr_cells(i).val));
                        write(fail_reason, string'(" got="));
                        write(fail_reason, slv_to_hex(mem.read24(fr_cells(i).addr)));
                        case_failed := true;
                    end if;
                end loop;

                -- Cycle list
                -- F9 (2026-05-03): null cycles (valid='0', addr=null in SST)
                -- represent CPU-internal / halted cycles where the external
                -- bus state is meaningless on real silicon. SST records
                -- VDA=0/VPA=0/RWB=0 defaults regardless of actual driving.
                -- Skip ALL bus-flag comparisons on null cycles, matching
                -- silicon's "informational only" semantics.
                for i in 0 to n_cy - 1 loop
                    if not case_failed and cyc_exp(i).valid = '1' then
                        if observed(i).addr /= std_logic_vector(cyc_exp(i).addr) then
                            write(fail_reason, string'("CY["));
                            write(fail_reason, integer'image(i));
                            write(fail_reason, string'("] addr exp="));
                            write(fail_reason, hex_str(to_integer(cyc_exp(i).addr), 6));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(observed(i).addr));
                            case_failed := true;
                        elsif observed(i).data /= cyc_exp(i).data then
                            write(fail_reason, string'("CY["));
                            write(fail_reason, integer'image(i));
                            write(fail_reason, string'("] data exp="));
                            write(fail_reason, slv_to_hex(cyc_exp(i).data));
                            write(fail_reason, string'(" got="));
                            write(fail_reason, slv_to_hex(observed(i).data));
                            case_failed := true;
                        end if;

                        if not case_failed then
                            if observed(i).vda /= cyc_exp(i).d_f then
                                write(fail_reason, string'("CY["));
                                write(fail_reason, integer'image(i));
                                write(fail_reason, string'("] VDA exp="));
                                write(fail_reason, std_logic'image(cyc_exp(i).d_f)(2 to 2));
                                write(fail_reason, string'(" got="));
                                write(fail_reason, std_logic'image(observed(i).vda)(2 to 2));
                                case_failed := true;
                            elsif observed(i).vpa /= cyc_exp(i).p_f then
                                write(fail_reason, string'("CY["));
                                write(fail_reason, integer'image(i));
                                write(fail_reason, string'("] VPA exp="));
                                write(fail_reason, std_logic'image(cyc_exp(i).p_f)(2 to 2));
                                write(fail_reason, string'(" got="));
                                write(fail_reason, std_logic'image(observed(i).vpa)(2 to 2));
                                case_failed := true;
                            elsif (observed(i).we = '1' and cyc_exp(i).r_f /= '1') or
                                  (observed(i).we = '0' and cyc_exp(i).r_f /= '0') then
                                write(fail_reason, string'("CY["));
                                write(fail_reason, integer'image(i));
                                write(fail_reason, string'("] RWB exp="));
                                write(fail_reason, std_logic'image(cyc_exp(i).r_f)(2 to 2));
                                write(fail_reason, string'(" got_we="));
                                write(fail_reason, std_logic'image(observed(i).we)(2 to 2));
                                case_failed := true;
                            elsif observed(i).mlb /= cyc_exp(i).l_f then
                                write(fail_reason, string'("CY["));
                                write(fail_reason, integer'image(i));
                                write(fail_reason, string'("] MLB exp="));
                                write(fail_reason, std_logic'image(cyc_exp(i).l_f)(2 to 2));
                                write(fail_reason, string'(" got="));
                                write(fail_reason, std_logic'image(observed(i).mlb)(2 to 2));
                                case_failed := true;
                            end if;
                        end if;
                    end if;
                end loop;
            end if;

            -------------------------------------------------------------------
            -- Result line
            -------------------------------------------------------------------
            if case_failed then
                fail_count := fail_count + 1;
                write(l, string'("FAIL case "));
                write(l, case_idx);
                write(l, string'(": "));
                write(l, fail_reason.all);
                writeline(output, l);
                deallocate(fail_reason);
                if verbose then
                    -- Dump observed cycles vs expected
                    for i in 0 to n_cy - 1 loop
                        write(l, string'("  CY[")); write(l, i); write(l, string'("] obs a="));
                        write(l, slv_to_hex(observed(i).addr));
                        write(l, string'(" d=")); write(l, slv_to_hex(observed(i).data));
                        write(l, string'(" we=")); write(l, std_logic'image(observed(i).we)(2 to 2));
                        write(l, string'(" vda=")); write(l, std_logic'image(observed(i).vda)(2 to 2));
                        write(l, string'(" vpa=")); write(l, std_logic'image(observed(i).vpa)(2 to 2));
                        write(l, string'(" mlb=")); write(l, std_logic'image(observed(i).mlb)(2 to 2));
                        write(l, string'(" | exp a="));
                        write(l, hex_str(to_integer(cyc_exp(i).addr), 6));
                        if cyc_exp(i).valid = '1' then
                            write(l, string'(" d=")); write(l, slv_to_hex(cyc_exp(i).data));
                        else
                            write(l, string'(" d=XX"));
                        end if;
                        write(l, string'(" rwb=")); write(l, std_logic'image(cyc_exp(i).r_f)(2 to 2));
                        write(l, string'(" vda=")); write(l, std_logic'image(cyc_exp(i).d_f)(2 to 2));
                        write(l, string'(" vpa=")); write(l, std_logic'image(cyc_exp(i).p_f)(2 to 2));
                        write(l, string'(" mlb=")); write(l, std_logic'image(cyc_exp(i).l_f)(2 to 2));
                        writeline(output, l);
                    end loop;
                    write(l, string'("  CAP pc=")); write(l, slv_to_hex(cap_pc));
                    write(l, string'(" sp=")); write(l, slv_to_hex(cap_sp));
                    write(l, string'(" p=")); write(l, slv_to_hex(cap_p));
                    write(l, string'(" a=")); write(l, slv_to_hex(cap_a));
                    write(l, string'(" x=")); write(l, slv_to_hex(cap_x));
                    write(l, string'(" y=")); write(l, slv_to_hex(cap_y));
                    write(l, string'(" d=")); write(l, slv_to_hex(cap_d));
                    write(l, string'(" dbr=")); write(l, slv_to_hex(cap_dbr));
                    write(l, string'(" pbr=")); write(l, slv_to_hex(cap_pbr));
                    write(l, string'(" e=")); write(l, std_logic'image(cap_ef)(2 to 2));
                    writeline(output, l);
                end if;
            else
                pass_count := pass_count + 1;
                if verbose then
                    write(l, string'("PASS case "));
                    write(l, case_idx);
                    writeline(output, l);
                end if;
            end if;

            rst_n <= '0';
            wait until rising_edge(clk);
        end loop;

        file_close(fin);

        report "================ SST RESULTS ================";
        write(l, string'("SST_RESULT pass="));
        write(l, pass_count);
        write(l, string'(" fail="));
        write(l, fail_count);
        write(l, string'(" skip="));
        write(l, skip_count);
        write(l, string'(" total="));
        write(l, pass_count + fail_count + skip_count);
        writeline(output, l);

        std.env.finish;
    end process main_proc;

end architecture;
