-- cpu_in_bridge_tb.vhd
--
-- Path B bench (2026-05-24): the model-CPU bench
-- (bridge_tb.vhd) passes 5/5 scenarios but every silicon build with
-- EFF_BRIDGE_ACTIVE=1 wedges. This bench replaces the model CPU with the
-- real P65C816 wrapper (cpu_65c816 entity) wired into scpu_async_bridge,
-- with a tiny mock arbiter on the clk_sys side that mimics the C64
-- arbiter's CPU0/4/8/C cadence and ack-pulse generation.
--
-- Verdict criterion: if dbg_pc reaches the reset vector target ($00:0200)
-- within the stop-time window, the bridge HDL is correct in sim and the
-- silicon wedge is a synthesis/integration issue (fitter timing skew,
-- missing SDC constraint, preserve attribute on wrong reg, etc.). If
-- dbg_pc stays at $00:0000 forever, the wedge reproduces in sim and the
-- bridge HDL itself has a bug --fixable in sim before any further builds.
--
-- ROM map (mock arbiter responds with):
--   $00:FFFC=$00 / $00:FFFD=$02  → reset vector $0200
--   $00:0200=$4C / $00:0201=$00 / $00:0202=$02  → JMP $0200 (tight loop)
--   default                       → $EA (NOP, safer than $00=BRK)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

entity cpu_in_bridge_tb is
	generic (
		-- 1 = matched clocks (regression net). 2 = clk_cpu=64MHz (target).
		RATIO : positive := 2;

		-- Stop time as ps for portability with --stop-time=Nps
		STOP_TIME_NS : positive := 50000
	);
end entity;

architecture sim of cpu_in_bridge_tb is

	constant CLK_SYS_PERIOD : time := 31.25 ns;
	constant CLK_CPU_PERIOD : time := CLK_SYS_PERIOD / RATIO;

	signal clk_cpu : std_logic := '0';
	signal clk_sys : std_logic := '0';
	signal reset   : std_logic := '1';

	-- CPU outputs (from cpu_65c816)
	signal cpu_addr     : unsigned(15 downto 0);
	signal cpu_addr_hi  : unsigned(7 downto 0);
	signal cpu_do       : unsigned(7 downto 0);
	signal cpu_we       : std_logic;
	signal cpu_vpa      : std_logic;
	signal cpu_vda      : std_logic;

	-- CPU inputs (driven by bridge)
	signal cpu_di       : unsigned(7 downto 0);
	signal cpu_rdy      : std_logic;

	-- CPU debug
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

	-- CPU misc
	signal nmi_n       : std_logic := '1';
	signal nmi_ack_unused : std_logic;
	signal irq_n       : std_logic := '1';
	signal emu_mode    : std_logic;
	signal cpu_enable  : std_logic;
	signal diIO        : unsigned(7 downto 0) := (others => '1');
	signal doIO_unused : unsigned(7 downto 0);

	-- Bridge bus-side outputs
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

	-- cpu_enable now driven by bridge.cpu_enable_out (F.3' fix: aligned with rdy)

	-- C64 arbiter mock: 32-clk_sys sysCycleDef divided 4 ways (CPU0/4/8/C).
	-- We collapse to: strobe every 4 clk_sys, ack 2 clk_sys after strobe
	-- (mimics enableCpu = cpu_cyc_s(1)).
	signal slot_ctr     : unsigned(4 downto 0) := (others => '0');
	signal pending_addr : unsigned(15 downto 0) := (others => '0');
	signal pending_addr_hi : unsigned(7 downto 0) := (others => '0');
	signal pending_we   : std_logic := '0';
	signal pending_do   : unsigned(7 downto 0) := (others => '0');
	signal pending_valid : std_logic := '0';
	signal ack_delay    : unsigned(1 downto 0) := (others => '0');

	-- Wedge detector
	signal pc_ever_left_zero : std_logic := '0';
	signal max_pc_observed   : unsigned(15 downto 0) := (others => '0');

	-- Helper: ROM model
	function rom_byte(a_hi : unsigned(7 downto 0); a_lo : unsigned(15 downto 0)) return unsigned is
	begin
		if a_hi /= x"00" then
			return x"EA";
		end if;
		case to_integer(a_lo) is
			when 16#FFFC# => return x"00";  -- reset vec lo
			when 16#FFFD# => return x"02";  -- reset vec hi
			when 16#FFFE# => return x"00";  -- irq vec lo
			when 16#FFFF# => return x"02";  -- irq vec hi (loops back to ROM)
			when 16#0200# => return x"4C";  -- JMP abs
			when 16#0201# => return x"03";  -- target lo (jump to $0203)
			when 16#0202# => return x"02";  -- target hi
			when 16#0203# => return x"EA";  -- NOP at jump target
			when 16#0204# => return x"4C";  -- another JMP
			when 16#0205# => return x"00";
			when 16#0206# => return x"02";  -- jump back to $0200
			when others   => return x"EA";
		end case;
	end function;

begin

	-- ------------------------------------------------------------------
	-- Clock generators
	-- ------------------------------------------------------------------
	clk_sys <= not clk_sys after CLK_SYS_PERIOD / 2;
	clk_cpu <= not clk_cpu after CLK_CPU_PERIOD / 2;

	-- Reset: 200 ns
	reset <= '1', '0' after 200 ns;

	-- cpu_enable is now driven below by bridge.cpu_enable_out

	-- ------------------------------------------------------------------
	-- DUT: real cpu_65c816 wrapper
	-- ------------------------------------------------------------------
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

	-- ------------------------------------------------------------------
	-- DUT: bridge under test (F.3' MCP path engaged)
	-- ------------------------------------------------------------------
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

	-- ------------------------------------------------------------------
	-- Mock arbiter on clk_sys: emits one bus_request_strobe pulse every
	-- 4 clk_sys cycles. Two cycles after the strobe, if vpa/vda was
	-- observed at the strobe edge, capture the address/we/do and fire
	-- bus_ack_pulse with the ROM lookup result on bus_di.
	-- ------------------------------------------------------------------
	mock_arb : process(clk_sys)
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
				-- Default: deassert pulses
				bus_request_strobe <= '0';
				bus_ack_pulse      <= '0';

				slot_ctr <= slot_ctr + 1;

				-- Strobe every 4 clk_sys (mimic CYCLE_CPU0/4/8/C cadence).
				if slot_ctr(1 downto 0) = "11" then
					bus_request_strobe <= '1';
					if bus_vpa = '1' or bus_vda = '1' then
						pending_addr    <= bus_addr;
						pending_addr_hi <= bus_addr_hi;
						pending_we      <= bus_we;
						pending_do      <= bus_do;
						pending_valid   <= '1';
						ack_delay       <= "10";  -- 2 cycles
					end if;
				end if;

				-- Count down to ack
				if pending_valid = '1' then
					if ack_delay = "00" then
						bus_ack_pulse <= '1';
						bus_di        <= rom_byte(pending_addr_hi, pending_addr);
						pending_valid <= '0';
					else
						ack_delay <= ack_delay - 1;
					end if;
				end if;
			end if;
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- Trace observer: dump bridge state every 25 ns for first 2000 ns
	-- ------------------------------------------------------------------
	trace_proc : process
		variable l : line;
	begin
		wait for 200 ns;  -- skip reset
		while now < 2000 ns loop
			wait for 25 ns;
			write(l, string'("@"));
			write(l, now);
			write(l, string'(" PC=$"));
			hwrite(l, std_logic_vector(dbg_pc));
			write(l, string'(" vpa="));
			write(l, cpu_vpa);
			write(l, string'(" vda="));
			write(l, cpu_vda);
			write(l, string'(" addr=$"));
			hwrite(l, std_logic_vector(cpu_addr));
			write(l, string'(" rdy="));
			write(l, cpu_rdy);
			write(l, string'(" en="));
			write(l, cpu_enable);
			write(l, string'(" strobe="));
			write(l, bus_request_strobe);
			write(l, string'(" ack="));
			write(l, bus_ack_pulse);
			write(l, string'(" di=$"));
			hwrite(l, std_logic_vector(cpu_di));
			writeline(output, l);
		end loop;
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Wedge detector: track if dbg_pc ever moves off $0000
	-- ------------------------------------------------------------------
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
			end if;
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- Stimulus / verdict
	-- ------------------------------------------------------------------
	stim : process
		variable l : line;
	begin
		wait for STOP_TIME_NS * 1 ns;

		write(l, string'("=== cpu_in_bridge_tb verdict ==="));
		writeline(output, l);
		write(l, string'("RATIO = "));
		write(l, RATIO);
		writeline(output, l);
		write(l, string'("Final dbg_pc = $"));
		hwrite(l, std_logic_vector(dbg_pc));
		writeline(output, l);
		write(l, string'("Final dbg_pbr = $"));
		hwrite(l, std_logic_vector(dbg_pbr));
		writeline(output, l);
		write(l, string'("Final dbg_sp = $"));
		hwrite(l, std_logic_vector(dbg_sp));
		writeline(output, l);
		write(l, string'("Max dbg_pc observed = $"));
		hwrite(l, std_logic_vector(max_pc_observed));
		writeline(output, l);
		write(l, string'("pc_ever_left_zero = "));
		write(l, std_logic'image(pc_ever_left_zero));
		writeline(output, l);

		if pc_ever_left_zero = '0' then
			write(l, string'("VERDICT: WEDGE REPRODUCED IN SIM --bridge HDL bug; PC=$0000 forever"));
			writeline(output, l);
			assert false report "wedge reproduced in sim" severity failure;
		elsif max_pc_observed >= x"0200" then
			write(l, string'("VERDICT: PASS --CPU reached the reset-vector target. Bridge works in sim."));
			writeline(output, l);
		else
			write(l, string'("VERDICT: PARTIAL --CPU advanced but did not reach $0200. Investigate further."));
			writeline(output, l);
		end if;

		std.env.stop;
	end process;

end architecture;
