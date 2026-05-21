-- scpu_async_bridge.vhd
--
-- Sits between the P65C816 and the legacy clk_sys bus arbiter. Owns the
-- eventual CDC sync FFs, RDY-stall state machine, and fast/slow address
-- decoder so neither the CPU nor the arbiter has to know about clock
-- domain crossings.
--
-- Current state: passthrough + dead handshake scaffolding. The BRIDGE_ACTIVE
-- constant is '0', so the cpu_di_out / cpu_rdy_out muxes select the direct
-- bus signals and the synthesiser eliminates the unused FF chains and state
-- machine. Flipping BRIDGE_ACTIVE to '1' wakes up the slow-path handshake
-- (which today still resolves in one clk_cpu because clk_cpu = clk_sys).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity scpu_async_bridge is
generic (
	-- '0' = passthrough (today's hardware default); '1' = activate the
	-- slow-path handshake. Held as a generic so the GHDL bench can flip
	-- it independently of the synthesised hardware build.
	BRIDGE_ACTIVE : std_logic := '0';
	-- '0' = no fast-path cache (today); '1' = serve ZP+stack reads from a
	-- bridge-local BRAM with CPU writes write-through to both cache and bus.
	CACHE_ACTIVE  : std_logic := '0'
);
port (
	clk_cpu       : in  std_logic;
	clk_sys       : in  std_logic;
	reset         : in  std_logic;

	-- CPU side (P65C816, clk_cpu domain)
	cpu_addr_in    : in  unsigned(15 downto 0);
	cpu_addr_hi_in : in  unsigned(7 downto 0);
	cpu_do_in      : in  unsigned(7 downto 0);
	cpu_we_in      : in  std_logic;
	cpu_vpa_in     : in  std_logic;
	cpu_vda_in     : in  std_logic;
	cpu_di_out     : out unsigned(7 downto 0);
	cpu_rdy_out    : out std_logic;

	-- Bus side (legacy arbiter, clk_sys domain)
	bus_addr_out    : out unsigned(15 downto 0);
	bus_addr_hi_out : out unsigned(7 downto 0);
	bus_do_out      : out unsigned(7 downto 0);
	bus_we_out      : out std_logic;
	bus_vpa_out     : out std_logic;
	bus_vda_out     : out std_logic;
	bus_di_in       : in  unsigned(7 downto 0);
	bus_rdy_in      : in  std_logic;

	-- Debug observability: keeps the decoder out of the pruning list
	dbg_is_slow    : out std_logic
);
end entity;

architecture rtl of scpu_async_bridge is
	signal is_slow_access : std_logic;

	-- clk_sys → clk_cpu sync chains. Two-FF each, sampled on clk_cpu. With
	-- clk_cpu = clk_sys today they collapse to a 2-cycle pipeline; when
	-- clk_cpu becomes a real separate clock they prevent metastability.
	signal bus_rdy_sync1   : std_logic := '1';
	signal bus_rdy_sync2   : std_logic := '1';
	signal bus_di_sync1    : unsigned(7 downto 0) := (others => '0');
	signal bus_di_sync2    : unsigned(7 downto 0) := (others => '0');

	-- Handshake state machine (clk_cpu domain). IDLE = ready to accept the
	-- CPU's next bus access; WAIT_ACK = a slow-path access is in flight and
	-- the CPU's RDY is held low until the synced ack returns.
	type bridge_state_t is (IDLE, WAIT_ACK);
	signal bridge_state    : bridge_state_t := IDLE;
	signal cpu_di_latched  : unsigned(7 downto 0) := (others => '0');
	signal cpu_rdy_latched : std_logic := '1';

	-- Edge detect on the CPU's access lines so a single held vda level
	-- only triggers one WAIT_ACK entry, not one per clk_cpu cycle.
	signal cpu_vpa_d : std_logic := '0';
	signal cpu_vda_d : std_logic := '0';
	signal access_pulse : std_logic;

	-- ZP + stack write-through cache. 512 bytes covering bank $00 addresses
	-- $0000-$01FF — the hot zero page and the 6502 stack.
	--
	-- Structure mirrors cpu_cache.vhd's tag/valid pattern: data and valid
	-- both live in MLAB (LUT-based distributed RAM) with combinational
	-- reads. No M10K port-register, no 1-cycle BRAM latency, no read-
	-- during-write protection — `no_rw_check` plus the synchronous write
	-- process is sufficient.
	--
	-- Invalidation uses a 512-cycle flush counter (NOT a bulk reset of
	-- valid bits). Quartus cannot synthesise `cache_valid <= (others=>'0')`
	-- as MLAB — it either falls back to LUT-RAM with broken read-during-
	-- write semantics or refuses inference entirely. See cpu_cache.vhd
	-- lines 25-26 + 340-342 for the same idiom: a walker that clears one
	-- valid bit per cycle is MLAB-inferrable, a bulk reset is not.
	-- Earlier attempts at single-port M10K (see project_bridge_cache_d4_2
	-- _wedge.md) all wedged KERNAL with $AB on every ZP read because the
	-- valid bits were left in undefined power-on state.
	constant CACHE_BYTES : integer := 512;
	type cache_data_t is array (0 to CACHE_BYTES - 1) of unsigned(7 downto 0);
	signal cache_data       : cache_data_t;
	signal cache_valid      : std_logic_vector(0 to CACHE_BYTES - 1);
	signal cache_hit        : std_logic;
	signal cache_dout       : unsigned(7 downto 0) := (others => '0');
	signal cache_valid_dout : std_logic := '0';

	-- Flush walker. flush_active starts '1' (signal init) so the very first
	-- 512 clk_cpu cycles after FPGA load sweep all valid bits to '0'. After
	-- that the cache fills opportunistically on CPU writes.
	signal flush_active : std_logic := '1';
	signal flush_ctr    : unsigned(9 downto 0) := (others => '0');

	attribute ramstyle : string;
	attribute ramstyle of cache_data  : signal is "MLAB, no_rw_check";
	attribute ramstyle of cache_valid : signal is "MLAB, no_rw_check";

begin
	is_slow_access <= '1' when cpu_addr_hi_in = x"00" else '0';

	-- CDC sync from clk_sys signals into clk_cpu domain.
	process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			bus_rdy_sync1 <= bus_rdy_in;
			bus_rdy_sync2 <= bus_rdy_sync1;
			bus_di_sync1  <= bus_di_in;
			bus_di_sync2  <= bus_di_sync1;
			cpu_vpa_d     <= cpu_vpa_in;
			cpu_vda_d     <= cpu_vda_in;
		end if;
	end process;

	access_pulse <= (cpu_vpa_in and not cpu_vpa_d) or (cpu_vda_in and not cpu_vda_d);

	-- Cache hit: bank $00 + addr < $0200, and the flush walker is done.
	-- Combinational; reads happen on the same cycle from MLAB.
	cache_hit <= '1' when cpu_addr_hi_in = x"00"
	                   and cpu_addr_in(15 downto 9) = "0000000"
	                   and flush_active = '0'
	              else '0';

	-- Cache write process: synchronous. Reads (cache_dout / cache_valid_dout)
	-- are combinational below, served from MLAB. Wrapping in a generate so
	-- the cache disappears entirely from the netlist when CACHE_ACTIVE='0'.
	cache_gen : if CACHE_ACTIVE = '1' generate
		process(clk_cpu) begin
			if rising_edge(clk_cpu) then
				if reset = '1' then
					flush_active <= '1';
					flush_ctr    <= (others => '0');
				elsif flush_active = '1' then
					-- Walk one valid bit per cycle. flush_ctr(9) hits '1' after
					-- 512 entries cleared (counter goes 0..511 then wraps to 512).
					cache_valid(to_integer(flush_ctr(8 downto 0))) <= '0';
					if flush_ctr(9) = '1' then
						flush_active <= '0';
					else
						flush_ctr <= flush_ctr + 1;
					end if;
				elsif access_pulse = '1' and cpu_we_in = '1' and cache_hit = '1' then
					cache_data(to_integer(cpu_addr_in(8 downto 0)))  <= cpu_do_in;
					cache_valid(to_integer(cpu_addr_in(8 downto 0))) <= '1';
				end if;
			end if;
		end process;

		cache_dout       <= cache_data(to_integer(cpu_addr_in(8 downto 0)));
		cache_valid_dout <= cache_valid(to_integer(cpu_addr_in(8 downto 0)));
	end generate;

	-- Slow-path RDY-stall handshake. Inert while BRIDGE_ACTIVE='0' because
	-- the output mux below selects bus_rdy_in / bus_di_in directly; the
	-- state and latches are then dead code for the synthesiser.
	process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			if reset = '1' then
				bridge_state    <= IDLE;
				cpu_rdy_latched <= '1';
				cpu_di_latched  <= (others => '0');
			else
				case bridge_state is
					when IDLE =>
						cpu_rdy_latched <= '1';
						if access_pulse = '1' and is_slow_access = '1' then
							-- New slow-path access started this cycle: stall
							-- CPU and wait for the sys-side ack.
							cpu_rdy_latched <= '0';
							bridge_state    <= WAIT_ACK;
						end if;
					when WAIT_ACK =>
						if bus_rdy_sync2 = '1' then
							cpu_di_latched  <= bus_di_sync2;
							cpu_rdy_latched <= '1';
							bridge_state    <= IDLE;
						else
							cpu_rdy_latched <= '0';
						end if;
				end case;
			end if;
		end if;
	end process;

	-- Bus side: always passthrough (the bridge does not buffer CPU outputs
	-- on the way out today; that comes in a later phase if needed).
	bus_addr_out    <= cpu_addr_in;
	bus_addr_hi_out <= cpu_addr_hi_in;
	bus_do_out      <= cpu_do_in;
	bus_we_out      <= cpu_we_in;
	bus_vpa_out     <= cpu_vpa_in;
	bus_vda_out     <= cpu_vda_in;

	-- CPU side: when active, the handshake supplies di/rdy; when inert, the
	-- mux defaults to direct passthrough so the netlist matches the un-bridged
	-- build bit-for-bit. CACHE_ACTIVE='1' lets the cache win for ZP+stack
	-- reads, overriding whichever bridge path is selected.
	cpu_di_out <= cache_dout      when CACHE_ACTIVE  = '1' and cache_hit = '1' and cache_valid_dout = '1' else
	              cpu_di_latched  when BRIDGE_ACTIVE = '1' else
	              bus_di_in;
	cpu_rdy_out <= cpu_rdy_latched when BRIDGE_ACTIVE = '1' else bus_rdy_in;

	dbg_is_slow <= is_slow_access;
end architecture;
