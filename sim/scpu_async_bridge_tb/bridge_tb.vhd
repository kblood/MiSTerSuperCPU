-- bridge_tb.vhd
--
-- Stand-alone testbench for scpu_async_bridge (F.2 phase).
--
-- Strategy: instantiate the bridge with BRIDGE_ACTIVE='1' (the future
-- hardware path) and CACHE_ACTIVE='0' (cache disabled for handshake
-- testing). Drive the CPU side at clk_cpu @ 64 MHz with synthetic
-- requests, drive the bus side at clk_sys @ 32 MHz with a model
-- arbiter that emits a single-cycle ack pulse after a programmable
-- stall, and emit traces of both clock domains so the MCP / word-sync
-- handshake's round-trip is auditable.
--
-- This bench validates the toggle-FF request / ack-pulse handshake:
--   * CPU side toggles cpu_req_toggle_reg on vpa|vda assertion,
--     drops cpu_rdy_out, waits for sync'd ack-toggle round-trip.
--   * Bus side 2-FF-syncs the request toggle, edge-detects it to
--     set bus_request_pending_reg, samples bus_di_in when the model
--     arbiter pulses bus_ack_pulse_in, then toggles bus_ack_toggle_reg.
--
-- Scenarios:
--
--   E - 1-cycle arbiter response (fast slot, single read)
--   F - 4-cycle stall (models REU contention)
--   G - 16-cycle stall (models IO slot wait)
--   H - back-to-back accesses (stall_cycles=2)
--   I - write then read same address (stall_cycles=2)
--
-- Each scenario ends with an `assert` so the bench fails loudly on
-- mismatch instead of printing TRACE lines for manual review.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

entity bridge_tb is
	generic (
		-- F.2 upgrade (2026-05-23): parametric clk_cpu : clk_sys ratio.
		-- RATIO=1 → matched 32 MHz (regression net for F.1' diag bridge).
		-- RATIO=2 → 64:32 MHz (target for F.3' MCP bridge).
		-- RATIO=3 → 96:32 MHz future stretch goal.
		-- Pass via GHDL `-gRATIO=N` at elaboration.
		RATIO : positive := 2;

		-- PASSTHROUGH_MODE='1' validates the bridge's combinational
		-- passthrough path (current 67-line diag bridge). The CPU's
		-- cpu_rdy_out is expected to stay '1' throughout and cpu_di
		-- tracks bus_di in real time. This is the regression net
		-- against today's HEAD.
		--
		-- PASSTHROUGH_MODE='0' validates the F.3' two-stage MCP FSM
		-- (latch on vpa/vda, toggle on synced strobe edge). cpu_rdy
		-- drops on request, rises on ack round-trip. The bench's
		-- model arbiter must drive bus_request_strobe periodically or
		-- the bridge sits in CPU_REQ_PENDING forever.
		PASSTHROUGH_MODE : std_logic := '1';

		-- F.3' (2026-05-24): clk_sys cycles between strobe pulses. Models
		-- the C64 arbiter's CYCLE_CPU0/4/8/C cadence (cpu_cyc fires on
		-- every 4th sysCycle when turbo is fully on). The strobe is
		-- otherwise unused — the model arbiter still schedules ack from
		-- bus_vpa/vda assertion, so PASSTHROUGH_MODE='1' is unaffected.
		STROBE_PERIOD : positive := 4
	);
end entity;

architecture sim of bridge_tb is

	-- Two independent clock domains. CLK_CPU_PERIOD derives from RATIO
	-- so a single bench file can validate the bridge at any clk ratio.
	constant CLK_SYS_PERIOD : time := 31.25 ns;   -- 32 MHz arbiter / bus
	constant CLK_CPU_PERIOD : time := CLK_SYS_PERIOD / RATIO;

	signal clk_cpu : std_logic := '0';
	signal clk_sys : std_logic := '0';
	signal reset   : std_logic := '1';

	-- CPU-side stimulus (drives the bridge's CPU inputs)
	signal cpu_addr    : unsigned(15 downto 0) := (others => '0');
	signal cpu_addr_hi : unsigned(7 downto 0)  := (others => '0');
	signal cpu_do      : unsigned(7 downto 0)  := (others => '0');
	signal cpu_we      : std_logic := '0';
	signal cpu_vpa     : std_logic := '0';
	signal cpu_vda     : std_logic := '0';

	-- Bridge outputs back to the "CPU"
	signal cpu_di      : unsigned(7 downto 0);
	signal cpu_rdy     : std_logic;

	-- Bus-side ack (model arbiter drives these)
	signal bus_di            : unsigned(7 downto 0) := (others => '0');
	signal bus_ack_pulse     : std_logic := '0';
	-- F.3' prefetch strobe (model arbiter drives this)
	signal bus_request_strobe : std_logic := '0';

	-- Bridge outputs to the bus (we only observe these)
	signal bus_addr    : unsigned(15 downto 0);
	signal bus_addr_hi : unsigned(7 downto 0);
	signal bus_do      : unsigned(7 downto 0);
	signal bus_we      : std_logic;
	signal bus_vpa     : std_logic;
	signal bus_vda     : std_logic;
	signal dbg_is_slow : std_logic;

	-- Model arbiter control: stimulus sets this before each access
	signal stall_cycles  : integer := 1;

	-- Cross-process flag the stimulus can use to wait for the bridge
	-- to settle a request (cpu_rdy_out returning '1').
	signal stim_done     : std_logic := '0';

	-- Helper: compute the model arbiter's expected data byte for a
	-- given (bank, addr). Defined as low(addr) XOR bank so each test
	-- address has a unique, predictable value.
	function expected_data(addr : unsigned(15 downto 0);
	                       bank : unsigned(7 downto 0))
	                       return unsigned is
	begin
		return unsigned(addr(7 downto 0)) xor bank;
	end function;

	-- Helper to print one observation line
	procedure log_line(
		l         : inout line;
		t_now     : in time;
		tag       : in string;
		raddr     : in unsigned(15 downto 0);
		rbank     : in unsigned(7 downto 0);
		rdi       : in unsigned(7 downto 0);
		rrdy      : in std_logic;
		rslow     : in std_logic) is
	begin
		write(l, time'image(t_now));
		write(l, string'(" "));
		write(l, tag);
		write(l, string'(" bank="));
		hwrite(l, std_logic_vector(rbank));
		write(l, string'(" addr="));
		hwrite(l, std_logic_vector(raddr));
		write(l, string'(" cpu_di="));
		hwrite(l, std_logic_vector(rdi));
		write(l, string'(" cpu_rdy="));
		write(l, rrdy);
		write(l, string'(" is_slow="));
		write(l, rslow);
		writeline(output, l);
	end procedure;

	procedure log_bus(
		l        : inout line;
		t_now    : in time;
		raddr    : in unsigned(15 downto 0);
		rbank    : in unsigned(7 downto 0);
		rvpa     : in std_logic;
		rvda     : in std_logic;
		rwe      : in std_logic;
		rack     : in std_logic;
		rdi_in   : in unsigned(7 downto 0)) is
	begin
		write(l, time'image(t_now));
		write(l, string'(" BUS  bank="));
		hwrite(l, std_logic_vector(rbank));
		write(l, string'(" addr="));
		hwrite(l, std_logic_vector(raddr));
		write(l, string'(" vpa="));
		write(l, rvpa);
		write(l, string'(" vda="));
		write(l, rvda);
		write(l, string'(" we="));
		write(l, rwe);
		write(l, string'(" ack="));
		write(l, rack);
		write(l, string'(" bus_di="));
		hwrite(l, std_logic_vector(rdi_in));
		writeline(output, l);
	end procedure;

begin

	-- Independent clock generators (no phase relationship between domains)
	clk_cpu <= not clk_cpu after CLK_CPU_PERIOD / 2;
	clk_sys <= not clk_sys after CLK_SYS_PERIOD / 2;

	-- DUT
	dut : entity work.scpu_async_bridge
		generic map (
			BRIDGE_ACTIVE          => '1',
			CACHE_ACTIVE           => '0',
			-- Mirror PASSTHROUGH_MODE: when bench is in MCP mode,
			-- defeat the bridge's safety gate so EFF_BRIDGE_ACTIVE
			-- becomes '1' and the MCP FSM drives outputs.
			SAME_CLOCK_PASSTHROUGH => PASSTHROUGH_MODE
		)
		port map (
			clk_cpu        => clk_cpu,
			clk_sys        => clk_sys,
			reset          => reset,

			cpu_addr_in    => cpu_addr,
			cpu_addr_hi_in => cpu_addr_hi,
			cpu_do_in      => cpu_do,
			cpu_we_in      => cpu_we,
			cpu_vpa_in     => cpu_vpa,
			cpu_vda_in     => cpu_vda,
			cpu_di_out     => cpu_di,
			cpu_rdy_out    => cpu_rdy,
			cpu_enable_out => open,

			bus_addr_out     => bus_addr,
			bus_addr_hi_out  => bus_addr_hi,
			bus_do_out       => bus_do,
			bus_we_out       => bus_we,
			bus_vpa_out      => bus_vpa,
			bus_vda_out      => bus_vda,
			bus_di_in        => bus_di,
			bus_ack_pulse_in => bus_ack_pulse,
			bus_request_strobe_in => bus_request_strobe,

			dbg_is_slow      => dbg_is_slow
		);

	-- Per-clk_cpu trace
	trace_cpu : process(clk_cpu)
		variable l : line;
	begin
		if rising_edge(clk_cpu) then
			log_line(l, now, string'("TCPU "),
				cpu_addr, cpu_addr_hi, cpu_di, cpu_rdy, dbg_is_slow);
		end if;
	end process;

	-- Per-clk_sys trace (handshake visibility on the bus side)
	trace_sys : process(clk_sys)
		variable l : line;
	begin
		if rising_edge(clk_sys) then
			log_bus(l, now, bus_addr, bus_addr_hi,
				bus_vpa, bus_vda, bus_we, bus_ack_pulse, bus_di);
		end if;
	end process;

	-- Model arbiter: emits two clk_sys signals
	--   1. bus_request_strobe — single-cycle pulse every STROBE_PERIOD
	--      clk_sys. Models C64 arbiter's cpu_cyc firing on CYCLE_CPU0/4/8/C.
	--      The bridge's F.3' source FSM uses this to decide when to
	--      dispatch its cross-domain toggle.
	--   2. bus_ack_pulse — single-cycle pulse fired stall_cycles after
	--      bus_vpa/vda rises (i.e., after the bridge issues its request
	--      from CPU_WAIT_ACK). Models enableCpu_816.
	--
	-- The two are intentionally decoupled in the bench: a strobe can fire
	-- with no pending request (wasted slot — the bridge ignores it from
	-- CPU_IDLE) and a request can be in flight without strobes (it'll
	-- pick up the next one). Matches HW behavior.
	model_arb : process(clk_sys)
		variable prev_vreq    : std_logic := '0';
		variable wait_cnt     : integer   := 0;
		variable pending      : std_logic := '0';
		variable v_req_now    : std_logic := '0';
		variable strobe_ctr   : integer   := 0;
	begin
		if rising_edge(clk_sys) then
			-- Default: drive ack + strobe low each cycle unless fired below
			bus_ack_pulse      <= '0';
			bus_request_strobe <= '0';

			-- Edge-detect the bus request (vpa or vda asserted)
			v_req_now := bus_vpa or bus_vda;

			if reset = '1' then
				prev_vreq   := '0';
				wait_cnt    := 0;
				pending     := '0';
				strobe_ctr  := 0;
				bus_di      <= (others => '0');
			else
				-- Strobe cadence: pulse once every STROBE_PERIOD clk_sys
				if strobe_ctr = STROBE_PERIOD - 1 then
					bus_request_strobe <= '1';
					strobe_ctr := 0;
				else
					strobe_ctr := strobe_ctr + 1;
				end if;

				if pending = '0' and v_req_now = '1' and prev_vreq = '0' then
					-- New request: schedule the ack
					pending  := '1';
					wait_cnt := stall_cycles;
					-- Pre-drive the data value the arbiter would return.
					-- For writes, the bench still drives a value but the
					-- bridge will ignore di on its captured side because
					-- the CPU consumes nothing on a we='1' completion;
					-- it only needs the ack to release cpu_rdy.
					bus_di <= expected_data(bus_addr, bus_addr_hi);
				elsif pending = '1' then
					if wait_cnt > 1 then
						wait_cnt := wait_cnt - 1;
					else
						-- Fire the single-cycle ack pulse
						bus_ack_pulse <= '1';
						pending  := '0';
						wait_cnt := 0;
					end if;
				end if;
			end if;

			prev_vreq := v_req_now;
		end if;
	end process;

	-- Stimulus
	stim : process
		variable l        : line;
		variable expected : unsigned(7 downto 0);
		variable wait_n   : integer;

		-- Issue a single CPU access and validate the response.
		--
		-- PASSTHROUGH_MODE='1' (current diag bridge): the bridge is
		-- combinational; cpu_rdy is permanently '1'. The validation
		-- step is "wait for arbiter ack pulse on bus side, then sample
		-- cpu_di and check vs expected_data."
		--
		-- PASSTHROUGH_MODE='0' (future F.3' MCP bridge): wait for rdy
		-- to drop (request accepted by source-side FSM) and rise again
		-- (ack-toggle round-tripped), then sample cpu_di.
		procedure cpu_access(
			bank      : in unsigned(7 downto 0);
			addr      : in unsigned(15 downto 0);
			we        : in std_logic;
			do        : in unsigned(7 downto 0);
			max_wait  : in time) is
		begin
			wait until rising_edge(clk_cpu);
			cpu_addr_hi <= bank;
			cpu_addr    <= addr;
			cpu_do      <= do;
			cpu_we      <= we;
			cpu_vpa     <= '0';
			cpu_vda     <= '1';

			if PASSTHROUGH_MODE = '1' then
				-- Passthrough: wait for arbiter ack pulse. cpu_di will
				-- track bus_di combinationally; the ack pulse marks the
				-- moment bus_di holds the valid response.
				wait until bus_ack_pulse = '1' for max_wait;
				assert bus_ack_pulse = '1'
					report "cpu_access (passthrough): arbiter ack never fired"
					severity failure;
				-- Sample cpu_di mid-ack-pulse (held by arbiter's bus_di
				-- assignment until next request edge).
			else
				-- MCP FSM: wait for bridge to drop rdy (request accepted)
				wait until cpu_rdy = '0' for max_wait;
				assert cpu_rdy = '0'
					report "cpu_access (MCP): bridge never dropped cpu_rdy"
					severity failure;

				-- Wait for bridge to raise rdy (ack round-tripped)
				wait until cpu_rdy = '1' for max_wait;
				assert cpu_rdy = '1'
					report "cpu_access (MCP): ack-toggle never returned"
					severity failure;
			end if;

			-- De-assert request after completion. Hold vda='0' for at
			-- least one full clk_sys period so the model arbiter's edge
			-- detector reliably sees the de-assert before the next call
			-- raises vda again. (At RATIO=2 one clk_cpu < one clk_sys,
			-- so the original "wait one clk_cpu" was unsafe.)
			cpu_vda <= '0';
			cpu_we  <= '0';
			wait for CLK_SYS_PERIOD + CLK_CPU_PERIOD;
		end procedure;

	begin
		-- Reset: hold for 5 clk_sys cycles, then release
		reset <= '1';
		wait for 5 * CLK_SYS_PERIOD;
		reset <= '0';
		-- Settle a couple of clk_cpu cycles before stimulus
		wait for 4 * CLK_CPU_PERIOD;

		----------------------------------------------------------------
		-- Scenario E: 1-cycle arbiter response, single read @ $00:D012
		----------------------------------------------------------------
		write(l, string'("=== Scenario E: 1-cycle ack, read $00:D012 ==="));
		writeline(output, l);
		stall_cycles <= 1;
		cpu_access(x"00", x"D012", '0', x"00", 40 * CLK_CPU_PERIOD);
		expected := expected_data(x"D012", x"00");
		assert cpu_di = expected
			report "Scenario E FAILED: cpu_di mismatch"
			severity error;

		wait for 4 * CLK_CPU_PERIOD;

		----------------------------------------------------------------
		-- Scenario F: 4-cycle stall (REU contention model)
		----------------------------------------------------------------
		write(l, string'("=== Scenario F: 4-cycle stall, read $00:D012 ==="));
		writeline(output, l);
		stall_cycles <= 4;
		cpu_access(x"00", x"D012", '0', x"00", 60 * CLK_CPU_PERIOD);
		expected := expected_data(x"D012", x"00");
		assert cpu_di = expected
			report "Scenario F FAILED: cpu_di mismatch"
			severity error;

		wait for 4 * CLK_CPU_PERIOD;

		----------------------------------------------------------------
		-- Scenario G: 16-cycle stall (IO slot wait model)
		----------------------------------------------------------------
		write(l, string'("=== Scenario G: 16-cycle stall, read $02:1234 ==="));
		writeline(output, l);
		stall_cycles <= 16;
		cpu_access(x"02", x"1234", '0', x"00", 120 * CLK_CPU_PERIOD);
		expected := expected_data(x"1234", x"02");
		assert cpu_di = expected
			report "Scenario G FAILED: cpu_di mismatch"
			severity error;

		wait for 4 * CLK_CPU_PERIOD;

		----------------------------------------------------------------
		-- Scenario H: back-to-back accesses (no idle gap), stall=2
		--
		-- The cpu_access procedure already keeps vda=0 only for one
		-- clk_cpu tick between calls. Two back-to-back invocations
		-- model a CPU that immediately re-asserts vda on the next
		-- request. The request toggle must flip cleanly for both.
		----------------------------------------------------------------
		write(l, string'("=== Scenario H: back-to-back reads ==="));
		writeline(output, l);
		stall_cycles <= 2;
		cpu_access(x"00", x"0010", '0', x"00", 50 * CLK_CPU_PERIOD);
		expected := expected_data(x"0010", x"00");
		assert cpu_di = expected
			report "Scenario H FAILED: first read cpu_di mismatch"
			severity error;

		-- Immediately issue the second read (no extra wait gap)
		cpu_access(x"00", x"0011", '0', x"00", 50 * CLK_CPU_PERIOD);
		expected := expected_data(x"0011", x"00");
		assert cpu_di = expected
			report "Scenario H FAILED: second read cpu_di mismatch"
			severity error;

		wait for 4 * CLK_CPU_PERIOD;

		----------------------------------------------------------------
		-- Scenario I: write then read same address, stall=2
		--
		-- The bench is testing the handshake, not memory semantics:
		-- the model arbiter doesn't store the write. It ack's both
		-- requests and returns expected_data() on the read.
		----------------------------------------------------------------
		write(l, string'("=== Scenario I: write then read $00:0042 ==="));
		writeline(output, l);
		stall_cycles <= 2;
		-- Write $7F to $00:0042 (we accept whatever cpu_di returns;
		-- writes don't define a read value, but the bridge still
		-- needs to see ack to release cpu_rdy).
		cpu_access(x"00", x"0042", '1', x"7F", 50 * CLK_CPU_PERIOD);
		-- Read the same address
		cpu_access(x"00", x"0042", '0', x"00", 50 * CLK_CPU_PERIOD);
		expected := expected_data(x"0042", x"00");
		assert cpu_di = expected
			report "Scenario I FAILED: read-after-write cpu_di mismatch"
			severity error;

		wait for 4 * CLK_CPU_PERIOD;

		write(l, string'("=== DONE ==="));
		writeline(output, l);
		wait;
	end process;

end architecture;
