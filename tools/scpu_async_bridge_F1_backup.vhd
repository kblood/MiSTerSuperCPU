-- F.1 MCP/word-synchronizer bridge REFERENCE SNAPSHOT.
-- Restored 2026-05-23 from commit 7f9dced for Milestone B revival.
-- This file is OUT OF TREE for synthesis: not added to C64.qsf,
-- not compiled. The active bridge at C64_MiSTer/rtl/scpu_async_bridge.vhd
-- is a 67-line pure-wire diagnostic passthrough (post 80dc8d7) which
-- preserves baseline behavior bit-for-bit while we plan F.3' arbiter
-- prefetch (see docs/async_bridge_phase_f_revised.md).
--
-- Use this file for F.3' design archaeology only. When restoring as
-- the active bridge, add a SAME_CLOCK_PASSTHROUGH generic that
-- defaults to '1' so the MCP outputs are masked until F.3' arbiter
-- prefetch is ready.
--
-- scpu_async_bridge.vhd
--
-- MCP / word-synchronizer CDC bridge between the P65C816 (clk_cpu domain)
-- and the legacy clk_sys bus arbiter. Implements the canonical handshake
-- pattern from docs/hdl-coding-guidelines/24-cdc-multi-bit.md §3.3:
--
--   source toggle  --2FF-->  sink edge-detect
--        ^                          |
--        |                          v
--   sink ack toggle  <--2FF--  on bus_ack_pulse_in
--
-- Payload {addr, addr_hi, do, we, vpa, vda} latched at source, held stable
-- for the entire round-trip (payload-stable-hold invariant — anti-pattern
-- entry 60 in 90-anti-patterns.md). Bus-side payload crosses to clk_sys
-- unsynchronized but is guaranteed stable, so the sink can use it
-- combinationally once it has observed the synced request edge.
--
-- BRIDGE_ACTIVE='0' (default): output muxes select direct passthrough
-- (cpu_di_out <= bus_di_in, cpu_rdy_out <= '1'). The MCP FSM still
-- instantiates and toggles in the background but its outputs are not
-- driven into the system; the synthesiser will retain the registers
-- because they have observable side effects (toggles), but the netlist
-- behavior is identical to the un-bridged build.
--
-- BRIDGE_ACTIVE='1': the MCP path drives cpu_di_out and cpu_rdy_out.
-- bus_ack_pulse_in must be a single-cycle clk_sys pulse on the cycle
-- the arbiter would have latched cpuDi for the CPU (in fpga64_sid_iec.vhd
-- that's `enableCpu_816`).
--
-- Phase F.1 (2026-05-21) replaces the prior level-rdy + 2-cycle WAIT_ACK
-- scaffolding that wedged at clk_cpu=clk64 in three configurations
-- (memory/project_phaseE1_64mhz_wedge.md). The new handshake is the
-- prerequisite for the clk_cpu=clk64 deploy in Phase F.3.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity scpu_async_bridge is
generic (
	-- '0' = passthrough (today's hardware default); '1' = activate the
	-- MCP handshake. Held as a generic so the GHDL bench can flip it
	-- independently of the synthesised hardware build.
	BRIDGE_ACTIVE : std_logic := '0';
	-- '0' = no fast-path cache (today); '1' = serve ZP+stack reads from a
	-- bridge-local MLAB. Kept disabled; F.5 of the Phase F plan revisits
	-- it once the MCP topology has eliminated the cross-domain cpu_di mux.
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
	bus_addr_out     : out unsigned(15 downto 0);
	bus_addr_hi_out  : out unsigned(7 downto 0);
	bus_do_out       : out unsigned(7 downto 0);
	bus_we_out       : out std_logic;
	bus_vpa_out      : out std_logic;
	bus_vda_out      : out std_logic;
	bus_di_in        : in  unsigned(7 downto 0);
	-- Arbiter capture-strobe: one clk_sys cycle wide, pulses when the
	-- arbiter would normally latch cpuDi for the CPU. In the C64 fork
	-- this is `enableCpu_816` (fpga64_sid_iec.vhd:2604) =
	-- enableCpu AND NOT dma_active AND supercpu_en.
	bus_ack_pulse_in : in  std_logic;

	-- Debug observability
	dbg_is_slow      : out std_logic
);
end entity;

architecture rtl of scpu_async_bridge is

	------------------------------------------------------------------
	-- Source domain (clk_cpu) signals
	------------------------------------------------------------------
	-- The CPU-side FSM. CPU_IDLE = accepting new access; CPU_WAIT_ACK =
	-- request in flight, waiting for synced ack to round-trip back.
	type cpu_fsm_t is (CPU_IDLE, CPU_WAIT_ACK);
	signal cpu_fsm : cpu_fsm_t := CPU_IDLE;

	-- Latched request payload — held stable from req-toggle until ack
	-- (payload-stable-hold invariant).
	signal cpu_req_addr_reg    : unsigned(15 downto 0) := (others => '0');
	signal cpu_req_addr_hi_reg : unsigned(7 downto 0)  := (others => '0');
	signal cpu_req_do_reg      : unsigned(7 downto 0)  := (others => '0');
	signal cpu_req_we_reg      : std_logic := '0';
	signal cpu_req_vpa_reg     : std_logic := '0';
	signal cpu_req_vda_reg     : std_logic := '0';

	-- Request toggle — flipped on each new CPU access.
	signal cpu_req_toggle_reg  : std_logic := '0';

	-- 2-FF sync chain for the sink-side ack toggle into clk_cpu domain.
	signal ack_sync1_reg       : std_logic := '0';
	signal ack_sync2_reg       : std_logic := '0';

	-- Captured read data — only reloaded when ack is observed.
	signal bus_di_capture_reg  : unsigned(7 downto 0) := (others => '0');

	-- Stall signal driven to the CPU.
	signal cpu_rdy_reg         : std_logic := '1';

	------------------------------------------------------------------
	-- Sink domain (clk_sys) signals
	------------------------------------------------------------------
	-- 2-FF sync chain of the source-side req toggle into clk_sys domain,
	-- plus a 3rd register for clean edge-detect (sync2 vs sync3 XOR).
	signal req_sync1_reg       : std_logic := '0';
	signal req_sync2_reg       : std_logic := '0';
	signal req_sync3_reg       : std_logic := '0';

	-- Pending flag — set on req edge, cleared on bus_ack_pulse_in capture.
	signal bus_request_pending_reg : std_logic := '0';

	-- Ack toggle — flipped on the same cycle the sink captures the read.
	signal bus_ack_toggle_reg  : std_logic := '0';

	-- Captured read payload (kept for symmetry/debug — the actual capture
	-- the CPU reads happens in bus_di_capture_reg on the clk_cpu side).
	signal bus_di_reg          : unsigned(7 downto 0) := (others => '0');

	------------------------------------------------------------------
	-- Quartus synchronizer attributes (per doc 23 §3.1 + doc 24 §5).
	-- preserve=true keeps the 2-FF chain from being optimised away;
	-- SYNCHRONIZER_IDENTIFICATION ensures Quartus reports MTBF in the
	-- Synchronizer Statistics report.
	------------------------------------------------------------------
	attribute preserve         : boolean;
	attribute altera_attribute : string;

	attribute preserve of req_sync1_reg : signal is true;
	attribute preserve of req_sync2_reg : signal is true;
	attribute preserve of ack_sync1_reg : signal is true;
	attribute preserve of ack_sync2_reg : signal is true;

	attribute altera_attribute of req_sync1_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of req_sync2_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of ack_sync1_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of ack_sync2_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";

	------------------------------------------------------------------
	-- Legacy fast/slow address decoder retained for dbg_is_slow port.
	-- The MCP path routes every access through the handshake — there is
	-- no separate fast-path bypass (decision point #2 default).
	------------------------------------------------------------------
	signal is_slow_access : std_logic;

	------------------------------------------------------------------
	-- ZP + stack cache (CACHE_ACTIVE='0' for F.1; F.5 revisits).
	-- Structure unchanged from D4 scaffolding: 512-byte MLAB + 512-cycle
	-- flush walker. Wrapped in cache_gen so it disappears from the
	-- netlist when disabled.
	------------------------------------------------------------------
	constant CACHE_BYTES : integer := 512;
	type cache_data_t is array (0 to CACHE_BYTES - 1) of unsigned(7 downto 0);
	signal cache_data       : cache_data_t;
	signal cache_valid      : std_logic_vector(0 to CACHE_BYTES - 1);
	signal cache_hit        : std_logic;
	signal cache_dout       : unsigned(7 downto 0) := (others => '0');
	signal cache_valid_dout : std_logic := '0';

	signal flush_active : std_logic := '1';
	signal flush_ctr    : unsigned(9 downto 0) := (others => '0');

	-- For the cache write-side: detect a new CPU access pulse so a held
	-- vda doesn't write the same byte every clk_cpu cycle.
	signal cpu_vpa_d : std_logic := '0';
	signal cpu_vda_d : std_logic := '0';
	signal access_pulse : std_logic;

	attribute ramstyle : string;
	attribute ramstyle of cache_data  : signal is "MLAB, no_rw_check";
	attribute ramstyle of cache_valid : signal is "MLAB, no_rw_check";

begin
	------------------------------------------------------------------
	-- Legacy combinational decode (debug + cache hit only)
	------------------------------------------------------------------
	is_slow_access <= '1' when cpu_addr_hi_in = x"00" else '0';
	dbg_is_slow    <= is_slow_access;

	cache_hit <= '1' when cpu_addr_hi_in = x"00"
	                   and cpu_addr_in(15 downto 9) = "0000000"
	                   and flush_active = '0'
	              else '0';

	------------------------------------------------------------------
	-- Source domain (clk_cpu): MCP request side
	------------------------------------------------------------------
	-- Sync the sink-side ack toggle into clk_cpu, run the request FSM.
	-- The ack-sync chain MUST be in its own process so synthesis sees
	-- a clean register-to-register topology with no combinational logic
	-- between the source register (bus_ack_toggle_reg) and the first
	-- sync FF (per doc 23 §3.1).
	ack_sync : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			ack_sync1_reg <= bus_ack_toggle_reg;
			ack_sync2_reg <= ack_sync1_reg;
		end if;
	end process;

	cpu_side : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			if reset = '1' then
				cpu_fsm             <= CPU_IDLE;
				cpu_req_toggle_reg  <= '0';
				cpu_rdy_reg         <= '1';
				cpu_req_addr_reg    <= (others => '0');
				cpu_req_addr_hi_reg <= (others => '0');
				cpu_req_do_reg      <= (others => '0');
				cpu_req_we_reg      <= '0';
				cpu_req_vpa_reg     <= '0';
				cpu_req_vda_reg     <= '0';
				bus_di_capture_reg  <= (others => '0');
			else
				case cpu_fsm is
					when CPU_IDLE =>
						cpu_rdy_reg <= '1';
						if cpu_vpa_in = '1' or cpu_vda_in = '1' then
							-- Latch payload BEFORE toggling req. The payload
							-- crosses clk_cpu→clk_sys unsynchronized; the
							-- payload-stable-hold rule guarantees it doesn't
							-- change again until ack returns.
							cpu_req_addr_reg    <= cpu_addr_in;
							cpu_req_addr_hi_reg <= cpu_addr_hi_in;
							cpu_req_do_reg      <= cpu_do_in;
							cpu_req_we_reg      <= cpu_we_in;
							cpu_req_vpa_reg     <= cpu_vpa_in;
							cpu_req_vda_reg     <= cpu_vda_in;
							cpu_req_toggle_reg  <= not cpu_req_toggle_reg;
							cpu_rdy_reg         <= '0';
							cpu_fsm             <= CPU_WAIT_ACK;
						end if;
					when CPU_WAIT_ACK =>
						-- Ack observed when synced toggle catches up to req.
						if ack_sync2_reg = cpu_req_toggle_reg then
							-- Capture read data. The bus_di_in net crosses
							-- unsynchronized — safe here because the sink
							-- has held it stable since the cycle the arbiter
							-- pulsed bus_ack_pulse_in (the sink registers
							-- bus_di_in into bus_di_reg on that cycle).
							bus_di_capture_reg <= bus_di_reg;
							cpu_rdy_reg        <= '1';
							cpu_fsm            <= CPU_IDLE;
						end if;
				end case;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Sink domain (clk_sys): MCP response side
	------------------------------------------------------------------
	-- Sync the source req toggle into clk_sys with edge-detect.
	req_sync : process(clk_sys) begin
		if rising_edge(clk_sys) then
			req_sync1_reg <= cpu_req_toggle_reg;
			req_sync2_reg <= req_sync1_reg;
			req_sync3_reg <= req_sync2_reg;
		end if;
	end process;

	sys_side : process(clk_sys) begin
		if rising_edge(clk_sys) then
			if reset = '1' then
				bus_ack_toggle_reg      <= '0';
				bus_request_pending_reg <= '0';
				bus_di_reg              <= (others => '0');
			else
				-- New request crossed in?
				if req_sync2_reg /= req_sync3_reg then
					bus_request_pending_reg <= '1';
				end if;

				-- Arbiter says "this is the cycle for the latched access".
				if bus_request_pending_reg = '1' and bus_ack_pulse_in = '1' then
					bus_di_reg              <= bus_di_in;
					bus_request_pending_reg <= '0';
					bus_ack_toggle_reg      <= not bus_ack_toggle_reg;
				end if;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Cache (held inert at CACHE_ACTIVE='0' for F.1)
	------------------------------------------------------------------
	cache_edge : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			cpu_vpa_d <= cpu_vpa_in;
			cpu_vda_d <= cpu_vda_in;
		end if;
	end process;
	access_pulse <= (cpu_vpa_in and not cpu_vpa_d) or (cpu_vda_in and not cpu_vda_d);

	cache_gen : if CACHE_ACTIVE = '1' generate
		process(clk_cpu) begin
			if rising_edge(clk_cpu) then
				if reset = '1' then
					flush_active <= '1';
					flush_ctr    <= (others => '0');
				elsif flush_active = '1' then
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

	------------------------------------------------------------------
	-- Output muxes
	------------------------------------------------------------------
	-- Bus side:
	--   * BRIDGE_ACTIVE='1' → drive from latched request regs (held stable
	--     for the entire round-trip; gated by request-pending so vpa/vda
	--     fall back to '0' between accesses).
	--   * BRIDGE_ACTIVE='0' → straight passthrough from cpu_*_in. This
	--     preserves the un-bridged netlist behavior bit-for-bit so a
	--     BRIDGE_ACTIVE='0' build matches the pre-rewrite baseline.
	bus_addr_out    <= cpu_req_addr_reg    when BRIDGE_ACTIVE = '1' else cpu_addr_in;
	bus_addr_hi_out <= cpu_req_addr_hi_reg when BRIDGE_ACTIVE = '1' else cpu_addr_hi_in;
	bus_do_out      <= cpu_req_do_reg      when BRIDGE_ACTIVE = '1' else cpu_do_in;
	bus_we_out      <= cpu_req_we_reg      when BRIDGE_ACTIVE = '1' else cpu_we_in;
	bus_vpa_out     <= (cpu_req_vpa_reg and bus_request_pending_reg) when BRIDGE_ACTIVE = '1' else cpu_vpa_in;
	bus_vda_out     <= (cpu_req_vda_reg and bus_request_pending_reg) when BRIDGE_ACTIVE = '1' else cpu_vda_in;

	-- CPU side: when BRIDGE_ACTIVE='1', the handshake supplies di/rdy.
	-- When BRIDGE_ACTIVE='0', the bus_di_in / '1' passthrough preserves
	-- baseline behavior bit-for-bit. CACHE_ACTIVE='1' lets the cache win
	-- for ZP+stack reads, but only after the bridge path is in use.
	cpu_di_out <= cache_dout         when CACHE_ACTIVE  = '1' and cache_hit = '1' and cache_valid_dout = '1' else
	              bus_di_capture_reg when BRIDGE_ACTIVE = '1' else
	              bus_di_in;
	cpu_rdy_out <= cpu_rdy_reg when BRIDGE_ACTIVE = '1' else '1';

end architecture;
