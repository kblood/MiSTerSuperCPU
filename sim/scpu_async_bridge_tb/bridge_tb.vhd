-- bridge_tb.vhd
--
-- Stand-alone testbench for scpu_async_bridge.
--
-- Strategy: instantiate the bridge with BRIDGE_ACTIVE='1' (the future
-- hardware path), drive the CPU side with a sequence of synthetic
-- requests, drive the bus side with a model arbiter, and emit a trace
-- of every clk_cpu edge so the state machine's behaviour is auditable.
--
-- Two scenarios are exercised back-to-back in the same run:
--
--   Scenario A  -  bus_rdy_in held high. This is the "baLoc" wiring
--                  state we currently have in fpga64_sid_iec.vhd.
--                  Expected (buggy): bridge exits WAIT_ACK on the very
--                  next clk_cpu edge and latches whatever value
--                  bus_di_in carries at that moment, which has nothing
--                  to do with a real bus-access completion.
--
--   Scenario B  -  bus_rdy_in held low until the model arbiter has
--                  responded with the correct data, then pulsed high
--                  for one clk_sys cycle. This is the wiring the
--                  bridge actually needs.
--                  Expected (correct): cpu_di_out carries the arbiter's
--                  data once cpu_rdy_out returns high.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

entity bridge_tb is
end entity;

architecture sim of bridge_tb is

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

	-- Bus-side (model arbiter drives these)
	signal bus_di      : unsigned(7 downto 0) := (others => '0');
	signal bus_rdy     : std_logic := '0';

	-- Bridge outputs to the bus (we only observe these)
	signal bus_addr    : unsigned(15 downto 0);
	signal bus_addr_hi : unsigned(7 downto 0);
	signal bus_do      : unsigned(7 downto 0);
	signal bus_we      : std_logic;
	signal bus_vpa     : std_logic;
	signal bus_vda     : std_logic;
	signal dbg_is_slow : std_logic;

	-- 32 MHz both sides
	constant CLK_PERIOD : time := 31.25 ns;

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

begin

	-- Clocks
	clk_cpu <= not clk_cpu after CLK_PERIOD / 2;
	clk_sys <= not clk_sys after CLK_PERIOD / 2;

	-- DUT
	dut : entity work.scpu_async_bridge
		generic map (BRIDGE_ACTIVE => '1', CACHE_ACTIVE => '1')
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

			bus_addr_out    => bus_addr,
			bus_addr_hi_out => bus_addr_hi,
			bus_do_out      => bus_do,
			bus_we_out      => bus_we,
			bus_vpa_out     => bus_vpa,
			bus_vda_out     => bus_vda,
			bus_di_in       => bus_di,
			bus_rdy_in      => bus_rdy,

			dbg_is_slow    => dbg_is_slow
		);

	-- Per-clk_cpu trace
	trace : process(clk_cpu)
		variable l : line;
	begin
		if rising_edge(clk_cpu) then
			log_line(l, now, string'("TRACE"),
				cpu_addr, cpu_addr_hi, cpu_di, cpu_rdy, dbg_is_slow);
		end if;
	end process;

	-- Stimulus
	stim : process
		variable l : line;
	begin
		-- Reset
		reset <= '1';
		wait for 5 * CLK_PERIOD;
		reset <= '0';
		-- Bridge cache uses a 513-cycle flush walker after reset to clear
		-- the MLAB valid bits. Wait it out before exercising the cache.
		wait for 520 * CLK_PERIOD;

		write(l, string'("=== Scenario A: bus_rdy held HIGH (baLoc wiring) ==="));
		writeline(output, l);

		bus_rdy <= '1';
		bus_di  <= x"AA";

		-- Bank $00 slow read at $D012 (VIC raster)
		wait until rising_edge(clk_cpu);
		cpu_addr_hi <= x"00";
		cpu_addr    <= x"D012";
		cpu_vpa     <= '0';
		cpu_vda     <= '1';
		cpu_we      <= '0';

		-- Hold one clk_cpu and observe
		wait for 6 * CLK_PERIOD;

		-- Stop driving the access
		cpu_vda <= '0';
		wait for 2 * CLK_PERIOD;

		write(l, string'("=== Scenario B: bus_rdy gated by model arbiter ==="));
		writeline(output, l);

		-- Arbiter is silent for a few cycles, then drives bus_di and pulses bus_rdy
		bus_rdy <= '0';
		bus_di  <= x"5A";

		wait until rising_edge(clk_cpu);
		cpu_addr_hi <= x"00";
		cpu_addr    <= x"D012";
		cpu_vda     <= '1';

		-- Wait 4 cycles to simulate slow-bus delay
		wait for 4 * CLK_PERIOD;

		-- Arbiter answers with correct data + 1-cycle ack pulse
		bus_di  <= x"5A";
		bus_rdy <= '1';
		wait for CLK_PERIOD;
		bus_rdy <= '0';

		-- Continue observing the bridge settle
		wait for 6 * CLK_PERIOD;

		cpu_vda <= '0';
		wait for 4 * CLK_PERIOD;

		write(l, string'("=== Scenario C: fast-path read (bank $02 SuperRAM) ==="));
		writeline(output, l);

		bus_rdy <= '0';
		wait until rising_edge(clk_cpu);
		cpu_addr_hi <= x"02";
		cpu_addr    <= x"1234";
		cpu_vda     <= '1';

		wait for 4 * CLK_PERIOD;
		cpu_vda <= '0';
		wait for 2 * CLK_PERIOD;

		write(l, string'("=== Scenario D: ZP write-through + cache read ($00:0042) ==="));
		writeline(output, l);

		-- Step 1: CPU write of $7F to $00:0042
		bus_rdy <= '0';
		bus_di  <= x"00";
		wait until rising_edge(clk_cpu);
		cpu_addr_hi <= x"00";
		cpu_addr    <= x"0042";
		cpu_do      <= x"7F";
		cpu_we      <= '1';
		cpu_vda     <= '1';

		-- Pulse one cycle (typical write completes immediately at the cache)
		wait for CLK_PERIOD;
		cpu_vda <= '0';

		-- Provide ack so the slow-path leg also completes (write still goes
		-- through to the bus even on cache hit; write-through).
		bus_rdy <= '1';
		wait for CLK_PERIOD;
		bus_rdy <= '0';

		wait for 3 * CLK_PERIOD;

		-- Step 2: CPU read of $00:0042 — expect cache_dout = $7F
		cpu_we <= '0';
		wait until rising_edge(clk_cpu);
		cpu_vda <= '1';
		wait for 5 * CLK_PERIOD;
		cpu_vda <= '0';

		write(l, string'("=== DONE ==="));
		writeline(output, l);
		wait;
	end process;

end architecture;
