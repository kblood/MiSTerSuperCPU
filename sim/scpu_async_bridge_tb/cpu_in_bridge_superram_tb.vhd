-- cpu_in_bridge_superram_tb.vhd
--
-- Milestone B SuperRAM coverage (2026-05-30). Sibling to cpu_in_bridge_tb.vhd:
-- same real cpu_65c816 + active scpu_async_bridge (BRIDGE_ACTIVE='1',
-- SAME_CLOCK_PASSTHROUGH='0') + mock C64 arbiter, but the ROM program switches
-- to NATIVE mode (CLC/XCE) and exercises 24-bit long addressing into bank $02
-- (SuperRAM) with a LONGER arbiter ack latency than bank $00 — the real system
-- splits bank $00 (2-stage SDRAM) vs SuperRAM (3-stage). This is the historical
-- "LDA long bank transition" wedge locus that the matched-clock RMW bench
-- (cpu_in_bridge_tb) does NOT cover.
--
-- Program @ $00:0200 (reset vector target):
--   18           CLC
--   FB           XCE                 ; emulation -> native
--   A9 AB        LDA #$AB
--   8F 00 00 02  STA $02:0000        ; long store into SuperRAM bank $02
--   A9 00        LDA #$00            ; scrub A so the readback can't be stale-A
--   AF 00 00 02  LDA $02:0000        ; long load back from SuperRAM bank $02
--   85 D6        STA $D6             ; park loaded byte in zp for verdict
--   4C 10 02     JMP $0210           ; halt sentinel
--
-- Verdict criterion: reach the $0210 sentinel AND zp_ram($D6)=$AB AND
-- superram($0000)=$AB. That means a long store + long load THROUGH the bridge
-- to a higher-latency SuperRAM bank round-tripped correctly at clk_cpu=64MHz.
-- A wedge (PC stuck) or a wrong $D6 means the bridge mishandles the
-- variable-latency SuperRAM ack at 2:1.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

entity cpu_in_bridge_superram_tb is
	generic (
		RATIO        : positive := 2;
		STOP_TIME_NS : positive := 50000;
		-- iter-7 RDY-handshake safety proof (2026-05-31): when true, the mock
		-- arbiter drives GARBAGE ($DD) onto bus_di for the entire ack_delay
		-- stall window, putting the real value only on the ack cycle. This
		-- models the no-stale-latch claim the RDY-handshake relies on: a read
		-- held by rdy-low during a miss must latch the FRESH byte, never the
		-- stale/garbage on the bus during the wait. If $AB still round-trips
		-- with garbage on the bus throughout the stall, the CPU provably
		-- consumes data only at rdy-release => speculative alt-slot firing is
		-- safe by construction.
		INJECT_GARBAGE_DURING_STALL : boolean := false
	);
end entity;

architecture sim of cpu_in_bridge_superram_tb is

	constant CLK_SYS_PERIOD : time := 31.25 ns;
	constant CLK_CPU_PERIOD : time := CLK_SYS_PERIOD / RATIO;

	signal clk_cpu : std_logic := '0';
	signal clk_sys : std_logic := '0';
	signal reset   : std_logic := '1';

	signal cpu_addr     : unsigned(15 downto 0);
	signal cpu_addr_hi  : unsigned(7 downto 0);
	signal cpu_do       : unsigned(7 downto 0);
	signal cpu_we       : std_logic;
	signal cpu_vpa      : std_logic;
	signal cpu_vda      : std_logic;

	signal cpu_di       : unsigned(7 downto 0);
	signal cpu_rdy      : std_logic;

	signal dbg_pc       : unsigned(15 downto 0);
	signal dbg_sp       : unsigned(15 downto 0);
	signal dbg_p        : unsigned(7 downto 0);
	signal dbg_ir       : unsigned(7 downto 0);
	signal dbg_pbr      : unsigned(7 downto 0);
	signal dbg_dbr      : unsigned(7 downto 0);
	signal dbg_x        : unsigned(15 downto 0);
	signal dbg_y        : unsigned(15 downto 0);
	signal dbg_d        : unsigned(15 downto 0);
	signal dbg_state    : unsigned(3 downto 0);

	signal nmi_n       : std_logic := '1';
	signal nmi_ack_unused : std_logic;
	signal irq_n       : std_logic := '1';
	signal emu_mode    : std_logic;
	signal cpu_enable  : std_logic;
	signal diIO        : unsigned(7 downto 0) := (others => '1');
	signal doIO_unused : unsigned(7 downto 0);

	signal bus_addr     : unsigned(15 downto 0);
	signal bus_addr_hi  : unsigned(7 downto 0);
	signal bus_do       : unsigned(7 downto 0);
	signal bus_we       : std_logic;
	signal bus_vpa      : std_logic;
	signal bus_vda      : std_logic;
	signal bus_di       : unsigned(7 downto 0) := (others => '0');
	signal bus_ack_pulse     : std_logic := '0';
	signal bus_request_strobe : std_logic := '0';
	signal dbg_is_slow  : std_logic;

	signal slot_ctr     : unsigned(4 downto 0) := (others => '0');
	signal pending_addr : unsigned(15 downto 0) := (others => '0');
	signal pending_addr_hi : unsigned(7 downto 0) := (others => '0');
	signal pending_we   : std_logic := '0';
	signal pending_do   : unsigned(7 downto 0) := (others => '0');
	signal pending_valid : std_logic := '0';
	signal ack_delay    : unsigned(2 downto 0) := (others => '0');

	signal pc_ever_left_zero : std_logic := '0';
	signal max_pc_observed   : unsigned(15 downto 0) := (others => '0');
	signal went_native       : std_logic := '0';

	-- Bank $00 zero page (writable, fast = 2-cycle ack).
	type zp_ram_t is array (0 to 255) of unsigned(7 downto 0);
	signal zp_ram : zp_ram_t := (others => x"00");

	-- SuperRAM bank $02 page 0 (writable, SLOW = 4-cycle ack to model the
	-- 3-stage SDRAM split being longer than bank $00's 2-stage).
	signal superram : zp_ram_t := (others => x"00");

	-- ROM (instruction fetch region, bank $00).
	function rom_byte(a_hi : unsigned(7 downto 0); a_lo : unsigned(15 downto 0)) return unsigned is
	begin
		if a_hi /= x"00" then
			return x"EA";
		end if;
		case to_integer(a_lo) is
			when 16#FFFC# => return x"00";  -- reset vec lo
			when 16#FFFD# => return x"02";  -- reset vec hi
			when 16#FFFE# => return x"00";  -- irq vec lo
			when 16#FFFF# => return x"02";  -- irq vec hi
			-- $0200: CLC ; XCE  (-> native)
			when 16#0200# => return x"18";
			when 16#0201# => return x"FB";
			-- $0202: LDA #$AB
			when 16#0202# => return x"A9";
			when 16#0203# => return x"AB";
			-- $0204: STA $02:0000  (long store, opcode 8F + 24-bit operand)
			when 16#0204# => return x"8F";
			when 16#0205# => return x"00";
			when 16#0206# => return x"00";
			when 16#0207# => return x"02";
			-- $0208: LDA #$00  (scrub A)
			when 16#0208# => return x"A9";
			when 16#0209# => return x"00";
			-- $020A: LDA $02:0000  (long load, opcode AF + 24-bit operand)
			when 16#020A# => return x"AF";
			when 16#020B# => return x"00";
			when 16#020C# => return x"00";
			when 16#020D# => return x"02";
			-- $020E: STA $D6
			when 16#020E# => return x"85";
			when 16#020F# => return x"D6";
			-- $0210: JMP $0210  (halt sentinel)
			when 16#0210# => return x"4C";
			when 16#0211# => return x"10";
			when 16#0212# => return x"02";
			when others   => return x"EA";
		end case;
	end function;

begin

	clk_sys <= not clk_sys after CLK_SYS_PERIOD / 2;
	clk_cpu <= not clk_cpu after CLK_CPU_PERIOD / 2;
	reset <= '1', '0' after 200 ns;

	cpu : entity work.cpu_65c816
	port map (
		clk            => clk_cpu,
		enable         => cpu_enable,
		reset          => reset,
		nmi_n          => nmi_n,
		nmi_ack        => nmi_ack_unused,
		irq_n          => irq_n,
		rdy            => cpu_rdy,
		di             => cpu_di,
		do             => cpu_do,
		addr           => cpu_addr,
		we             => cpu_we,
		diIO           => diIO,
		doIO           => doIO_unused,
		addr_hi        => cpu_addr_hi,
		emulation_mode => emu_mode,
		vpa            => cpu_vpa,
		vda            => cpu_vda,
		dbg_pc         => dbg_pc,
		dbg_sp         => dbg_sp,
		dbg_p          => dbg_p,
		dbg_ir         => dbg_ir,
		dbg_pbr        => dbg_pbr,
		dbg_dbr        => dbg_dbr,
		dbg_x          => dbg_x,
		dbg_y          => dbg_y,
		dbg_d          => dbg_d,
		dbg_state      => dbg_state
	);

	bridge : entity work.scpu_async_bridge
	generic map (
		BRIDGE_ACTIVE          => '1',
		CACHE_ACTIVE           => '0',
		SAME_CLOCK_PASSTHROUGH => '0'
	)
	port map (
		clk_cpu               => clk_cpu,
		clk_sys               => clk_sys,
		reset                 => reset,
		cpu_addr_in           => cpu_addr,
		cpu_addr_hi_in        => cpu_addr_hi,
		cpu_do_in             => cpu_do,
		cpu_we_in             => cpu_we,
		cpu_vpa_in            => cpu_vpa,
		cpu_vda_in            => cpu_vda,
		cpu_di_out            => cpu_di,
		cpu_rdy_out           => cpu_rdy,
		bus_addr_out          => bus_addr,
		bus_addr_hi_out       => bus_addr_hi,
		bus_do_out            => bus_do,
		bus_we_out            => bus_we,
		bus_vpa_out           => bus_vpa,
		bus_vda_out           => bus_vda,
		bus_di_in             => bus_di,
		bus_ack_pulse_in      => bus_ack_pulse,
		bus_request_strobe_in => bus_request_strobe,
		cpu_enable_out        => cpu_enable,
		dbg_is_slow           => dbg_is_slow
	);

	-- Mock arbiter: strobe every 4 clk_sys. Bank $00 acks after 2 cycles;
	-- SuperRAM bank ($02) acks after 4 cycles (variable latency).
	mock_arb : process(clk_sys)
		variable di_v : unsigned(7 downto 0);
	begin
		if rising_edge(clk_sys) then
			if reset = '1' then
				slot_ctr        <= (others => '0');
				pending_valid   <= '0';
				ack_delay       <= (others => '0');
				bus_request_strobe <= '0';
				bus_ack_pulse   <= '0';
				bus_di          <= (others => '0');
			else
				bus_request_strobe <= '0';
				bus_ack_pulse      <= '0';
				slot_ctr <= slot_ctr + 1;

				if slot_ctr(1 downto 0) = "11" then
					bus_request_strobe <= '1';
					if bus_vpa = '1' or bus_vda = '1' then
						pending_addr    <= bus_addr;
						pending_addr_hi <= bus_addr_hi;
						pending_we      <= bus_we;
						pending_do      <= bus_do;
						pending_valid   <= '1';
						if bus_addr_hi = x"00" then
							ack_delay <= "010";  -- bank $00: 2-stage
						else
							ack_delay <= "100";  -- SuperRAM: longer (4)
						end if;
					end if;
				end if;

				if pending_valid = '1' then
					if ack_delay = "000" then
						bus_ack_pulse <= '1';
						if pending_addr_hi = x"00" and pending_addr(15 downto 8) = x"00" then
							-- bank $00 zero page (writable)
							if pending_we = '1' then
								zp_ram(to_integer(pending_addr(7 downto 0))) <= pending_do;
								di_v := pending_do;
							else
								di_v := zp_ram(to_integer(pending_addr(7 downto 0)));
							end if;
						elsif pending_addr_hi = x"02" and pending_addr(15 downto 8) = x"00" then
							-- SuperRAM bank $02 page 0 (writable)
							if pending_we = '1' then
								superram(to_integer(pending_addr(7 downto 0))) <= pending_do;
								di_v := pending_do;
							else
								di_v := superram(to_integer(pending_addr(7 downto 0)));
							end if;
						else
							di_v := rom_byte(pending_addr_hi, pending_addr);
						end if;
						bus_di        <= di_v;
						pending_valid <= '0';
					else
						-- Mid-stall: data is NOT ready. Drive garbage when the
						-- safety-proof generic is set, so a PASS proves the CPU
						-- never latched the bus during the rdy-low wait.
						if INJECT_GARBAGE_DURING_STALL then
							bus_di <= x"DD";
						end if;
						ack_delay <= ack_delay - 1;
					end if;
				end if;
			end if;
		end if;
	end process;

	wedge_watch : process(clk_cpu)
	begin
		if rising_edge(clk_cpu) then
			if reset = '0' then
				if dbg_pc /= x"0000" then
					pc_ever_left_zero <= '1';
				end if;
				if dbg_pc > max_pc_observed then
					max_pc_observed <= dbg_pc;
				end if;
				if emu_mode = '0' then
					went_native <= '1';
				end if;
			end if;
		end if;
	end process;

	stim : process
		variable l : line;
	begin
		wait for STOP_TIME_NS * 1 ns;

		write(l, string'("=== cpu_in_bridge_superram_tb verdict ===")); writeline(output, l);
		write(l, string'("RATIO = ")); write(l, RATIO); writeline(output, l);
		write(l, string'("Final dbg_pc = $")); hwrite(l, std_logic_vector(dbg_pc)); writeline(output, l);
		write(l, string'("Max dbg_pc observed = $")); hwrite(l, std_logic_vector(max_pc_observed)); writeline(output, l);
		write(l, string'("went_native = ")); write(l, std_logic'image(went_native)); writeline(output, l);
		write(l, string'("zp_ram($D6) = $")); hwrite(l, std_logic_vector(zp_ram(16#D6#))); writeline(output, l);
		write(l, string'("superram($0000) = $")); hwrite(l, std_logic_vector(superram(0))); writeline(output, l);

		if pc_ever_left_zero = '0' then
			write(l, string'("VERDICT: WEDGE REPRODUCED IN SIM -- PC=$0000 forever")); writeline(output, l);
			assert false report "wedge reproduced in sim" severity failure;
		elsif (max_pc_observed = x"0210" or max_pc_observed = x"0211" or max_pc_observed = x"0212")
		      and went_native = '1'
		      and superram(0) = x"AB" and zp_ram(16#D6#) = x"AB" then
			write(l, string'("VERDICT: PASS -- native long store+load through bridge to SuperRAM bank $02 round-tripped ($AB). Variable-latency SuperRAM ack handled at 2:1.")); writeline(output, l);
		elsif superram(0) /= x"AB" then
			write(l, string'("VERDICT: FAIL -- long STORE to SuperRAM didn't land (superram($0000)=$")); hwrite(l, std_logic_vector(superram(0))); write(l, string'(")")); writeline(output, l);
			assert false report "long store to SuperRAM failed" severity failure;
		elsif zp_ram(16#D6#) /= x"AB" then
			write(l, string'("VERDICT: FAIL -- long LOAD from SuperRAM returned stale/wrong data (zp $D6=$")); hwrite(l, std_logic_vector(zp_ram(16#D6#))); write(l, string'(", expected $AB)")); writeline(output, l);
			assert false report "long load from SuperRAM returned wrong data" severity failure;
		else
			write(l, string'("VERDICT: PARTIAL -- stuck at PC=$")); hwrite(l, std_logic_vector(dbg_pc)); writeline(output, l);
			assert false report "did not reach sentinel" severity failure;
		end if;

		std.env.stop;
	end process;

end architecture;
