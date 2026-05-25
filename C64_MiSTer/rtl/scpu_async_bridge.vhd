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
	CACHE_ACTIVE  : std_logic := '0';
	-- F.3' safety gate (2026-05-23) per docs/async_bridge_phase_f_revised.md:
	-- '1' = force outputs to combinational passthrough even when
	--       BRIDGE_ACTIVE='1' (the safe state during matched-clock builds).
	-- '0' = let BRIDGE_ACTIVE drive the actual selection.
	-- Effective bridge-active = BRIDGE_ACTIVE AND NOT SAME_CLOCK_PASSTHROUGH.
	-- This is the "lock against accidentally re-engaging the MCP at
	-- matched clocks during refactor" from the revised plan §F.1'.
	SAME_CLOCK_PASSTHROUGH : std_logic := '1'
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

	-- F.3' enable CDC (2026-05-24): 1-clk_cpu pulse, asserted on the SAME
	-- clk_cpu edge that releases cpu_rdy_out from CPU_WAIT_ACK->CPU_IDLE.
	-- This guarantees cpu_enable_out and cpu_rdy_out are both '1' in the
	-- same clk_cpu cycle, so P65C816's internal EN=RDY AND CE actually
	-- fires. Without this, sync chain skew at clk_cpu>clk_sys puts enable
	-- and rdy in adjacent (non-overlapping) clk_cpu cycles -> wedge.
	-- Verified in sim/scpu_async_bridge_tb/cpu_in_bridge_tb.vhd (2026-05-24).
	cpu_enable_out : out std_logic;

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

	-- F.3' arbiter prefetch strobe (2026-05-23). One clk_sys pulse fired
	-- 2 clk_sys cycles BEFORE bus_ack_pulse_in by the arbiter; lets the
	-- bridge start its MCP round-trip early so the CPU's data is ready
	-- by the time enableCpu_816 fires. Wired from `cpu_cyc` per
	-- docs/async_bridge_f3_prefetch_sketch.md. Unused while
	-- SAME_CLOCK_PASSTHROUGH='1' (the F.3' MCP path is masked).
	bus_request_strobe_in : in  std_logic := '0';

	-- Debug observability
	dbg_is_slow      : out std_logic;

	-- Milestone B v2 (2026-05-26 — Codex Design 3): bridge-internal UART
	-- probes per docs/milestone_b_bridge_probe_design.md §B AND today's
	-- handoff §2.1. v1 saturated at $FFFF before the first vblank sample
	-- because 16-bit counters at clk_cpu=32MHz fill in ~2ms while vblank
	-- arrives every ~20ms — Race β was UNTESTABLE, not falsified.
	--
	-- v2 changes:
	--   • RQ/AK counters now WRAP (free-running mod 65536), snapshotted in
	--     clk_cpu on synced vblank-rise → snapshot held stable until next
	--     frame, so the c64.sv 2-FF sync of the OUTPUTS is valid (the
	--     existing live-counter sync had multi-bit tearing per Codex).
	--   • WD (wait_dwell_max): max consecutive clk_cpu cycles spent in
	--     CPU_WAIT_ACK per frame. The real Race β detector — the bridge
	--     is structurally one-outstanding so RQ-AK ≤ 1 always, but a
	--     wedge in WAIT_ACK shows up as WD growing toward saturation.
	--   • FL (activity flags): sticky-per-frame {req_seen, ack_seen,
	--     wait_seen} → tells you whether the source FSM made ANY progress
	--     in the last frame. 8 bits wide for future expansion.
	--   • GM (gap_max): max RQ-AK divergence observed during the frame.
	--     Sanity check — should be 0 or 1 in healthy operation; any
	--     higher implies the one-outstanding invariant is broken.
	--   • dbg_vblank_sys_in: clk_sys vsync rising-edge trigger for the
	--     snapshot. 3-FF synced into clk_cpu inside the bridge.
	dbg_fsm_state           : out unsigned(3 downto 0);
	dbg_last_bus_di         : out unsigned(7 downto 0);
	dbg_req_count           : out unsigned(15 downto 0);
	dbg_ack_count           : out unsigned(15 downto 0);
	dbg_irq_vec_fetch_count : out unsigned(7 downto 0);
	dbg_wait_dwell_max      : out unsigned(15 downto 0);
	dbg_activity_flags      : out unsigned(7 downto 0);
	dbg_gap_max             : out unsigned(7 downto 0);
	dbg_vblank_sys_in       : in  std_logic := '0'
);
end entity;

architecture rtl of scpu_async_bridge is

	------------------------------------------------------------------
	-- Effective active gate (revised plan §F.1'):
	-- Outputs route through the MCP path only when BRIDGE_ACTIVE='1'
	-- AND SAME_CLOCK_PASSTHROUGH='0'. Default config (both at safe
	-- side) preserves the pre-rewrite passthrough behavior bit-for-bit.
	------------------------------------------------------------------
	constant EFF_BRIDGE_ACTIVE : std_logic :=
		BRIDGE_ACTIVE and (not SAME_CLOCK_PASSTHROUGH);

	------------------------------------------------------------------
	-- Source domain (clk_cpu) signals
	------------------------------------------------------------------
	-- Two-stage source FSM (F.3' implementation, 2026-05-24):
	--   CPU_IDLE        — accepting new access; vpa/vda triggers payload latch
	--   CPU_REQ_PENDING — payload captured, cpu_rdy=0, awaiting arbiter strobe
	--                     before issuing the cross-domain toggle
	--   CPU_WAIT_ACK    — toggle in flight, awaiting synced ack round-trip
	--
	-- Rationale (docs/async_bridge_f3_prefetch_sketch.md §1'):
	--   • Latch on vpa/vda so the CPU is stalled within 1 clk_cpu of its
	--     request — matches the rdy semantics the P65C816 expects.
	--   • Defer the actual toggle until synced strobe_edge so the sink-side
	--     sees the toggle right before bus_ack_pulse_in fires. Eliminates
	--     ghost toggles that would otherwise burn arbiter slots while the
	--     CPU has nothing to ask for.
	--   • Resolves the "strobe replaces vpa/vda vs additional gate vs
	--     two-stage" open question per docs/session_handoff.md.
	-- v6 (2026-05-24): 4-state FSM with explicit CPU_LATCH state. CPU_LATCH
	-- is the single clk_cpu when fresh di is presented and the CPU advances.
	-- WAIT_ACK match → LATCH (not IDLE) so the combinational gate (which
	-- keys on cpu_fsm=IDLE) stays inactive while CPU latches. Then
	-- LATCH → IDLE, where the gate forces en/rdy=0 if CPU has a NEW bus
	-- request asserted; internal cycles (vpa=0, vda=0) pass through the
	-- gate and advance freely via the registered en_reg=1, rdy_reg=1.
	type cpu_fsm_t is (CPU_IDLE, CPU_REQ_PENDING, CPU_WAIT_ACK, CPU_LATCH);
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

	-- 3-FF sync chain for the arbiter prefetch strobe into clk_cpu domain.
	-- The 3rd register lets us derive a clean one-cycle edge pulse
	-- (sync2 high AND sync3 low) — matches the sink-side req edge-detect
	-- pattern (req_sync2 / req_sync3) below.
	signal strobe_sync1_reg    : std_logic := '0';
	signal strobe_sync2_reg    : std_logic := '0';
	signal strobe_sync3_reg    : std_logic := '0';
	signal strobe_edge         : std_logic;

	-- Captured read data — only reloaded when ack is observed.
	signal bus_di_capture_reg  : unsigned(7 downto 0) := (others => '0');

	-- Stall signal driven to the CPU.
	signal cpu_rdy_reg         : std_logic := '1';

	-- F.3' enable CDC (2026-05-24): pulses '1' for exactly one clk_cpu when
	-- WAIT_ACK -> IDLE transitions (same edge that releases cpu_rdy_reg).
	signal cpu_enable_reg      : std_logic := '0';

	------------------------------------------------------------------
	-- Milestone B v2 probe counters (clk_cpu domain).
	--
	-- TOTALS (now WRAPPING, not saturating). dbg_req_count_reg flips on
	-- IDLE→REQ_PENDING; dbg_ack_count_reg flips on WAIT_ACK→LATCH.
	-- dbg_vec_count_reg is the 8-bit IRQ vector-fetch saturator (unchanged).
	------------------------------------------------------------------
	signal dbg_req_count_reg  : unsigned(15 downto 0) := (others => '0');
	signal dbg_ack_count_reg  : unsigned(15 downto 0) := (others => '0');
	signal dbg_vec_count_reg  : unsigned(7 downto 0)  := (others => '0');

	------------------------------------------------------------------
	-- v2 additions: vblank-snapshot registers (held stable for a full
	-- frame so the c64.sv 2-FF sync sees a slow-changing signal — the
	-- live-counter tearing problem Codex flagged).
	------------------------------------------------------------------
	signal dbg_req_snap_reg   : unsigned(15 downto 0) := (others => '0');
	signal dbg_ack_snap_reg   : unsigned(15 downto 0) := (others => '0');
	signal dbg_vec_snap_reg   : unsigned(7 downto 0)  := (others => '0');

	-- WAIT_ACK dwell tracker. dwell_reg counts clk_cpu cycles spent in
	-- WAIT_ACK in the current visit (resets to 0 on every other state);
	-- dwell_max_accum is the max-over-frame, saturating at $FFFF;
	-- dwell_max_snap is the vblank-latched output.
	signal wait_dwell_reg        : unsigned(15 downto 0) := (others => '0');
	signal wait_dwell_max_accum  : unsigned(15 downto 0) := (others => '0');
	signal wait_dwell_max_snap   : unsigned(15 downto 0) := (others => '0');

	-- Sticky activity flags (cleared on vblank-snap):
	--   bit 0 = req_seen   (any IDLE→REQ_PENDING this frame)
	--   bit 1 = ack_seen   (any WAIT_ACK→LATCH this frame)
	--   bit 2 = wait_seen  (any clk_cpu spent in WAIT_ACK this frame)
	--   bit 7 = dwell_sat  (wait_dwell_max_accum saturated to $FFFF)
	signal req_seen_accum   : std_logic := '0';
	signal ack_seen_accum   : std_logic := '0';
	signal wait_seen_accum  : std_logic := '0';
	signal dbg_flags_snap   : unsigned(7 downto 0) := (others => '0');

	-- Live RQ-AK gap (one-outstanding FSM should hold this at 0 or 1).
	-- gap_max_accum is the frame max, saturating at $FF; gap_max_snap
	-- is the vblank-latched output.
	signal gap_cur          : unsigned(7 downto 0) := (others => '0');
	signal gap_max_accum    : unsigned(7 downto 0) := (others => '0');
	signal gap_max_snap     : unsigned(7 downto 0) := (others => '0');

	-- vblank sync: clk_sys → clk_cpu 3-FF chain + rising-edge detect.
	-- Slow signal (60Hz NTSC / 50Hz PAL) so 3-FF level sync + edge-detect
	-- is the correct CDC pattern (docs/hdl-coding-guidelines/24-cdc...
	-- §3.1). 3 FFs (not 2) because we form the edge from vb_s2 XOR vb_s3.
	signal vb_s1            : std_logic := '0';
	signal vb_s2            : std_logic := '0';
	signal vb_s3            : std_logic := '0';
	signal vb_cpu_rise      : std_logic;

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

	attribute preserve of req_sync1_reg    : signal is true;
	attribute preserve of req_sync2_reg    : signal is true;
	attribute preserve of ack_sync1_reg    : signal is true;
	attribute preserve of ack_sync2_reg    : signal is true;
	attribute preserve of strobe_sync1_reg : signal is true;
	attribute preserve of strobe_sync2_reg : signal is true;

	-- Milestone B probe registers — preserved so synthesis doesn't
	-- re-time or collapse them, matching the Option F/G convention.
	attribute preserve of dbg_req_count_reg : signal is true;
	attribute preserve of dbg_ack_count_reg : signal is true;
	attribute preserve of dbg_vec_count_reg : signal is true;

	-- v2 additions: snapshot regs + dwell/gap trackers + vblank-sync chain.
	-- All preserve=true so Quartus does not collapse the per-frame snapshot
	-- pipeline (the OUTPUTS are slow but the source counters are fast).
	attribute preserve of dbg_req_snap_reg      : signal is true;
	attribute preserve of dbg_ack_snap_reg      : signal is true;
	attribute preserve of dbg_vec_snap_reg      : signal is true;
	attribute preserve of wait_dwell_reg        : signal is true;
	attribute preserve of wait_dwell_max_accum  : signal is true;
	attribute preserve of wait_dwell_max_snap   : signal is true;
	attribute preserve of dbg_flags_snap        : signal is true;
	attribute preserve of req_seen_accum       : signal is true;
	attribute preserve of ack_seen_accum       : signal is true;
	attribute preserve of wait_seen_accum      : signal is true;
	attribute preserve of gap_cur               : signal is true;
	attribute preserve of gap_max_accum         : signal is true;
	attribute preserve of gap_max_snap          : signal is true;
	attribute preserve of vb_s1                 : signal is true;
	attribute preserve of vb_s2                 : signal is true;
	attribute preserve of vb_s3                 : signal is true;

	-- Mark vb_s1/s2 as the synchronizer pair so Quartus's Synchronizer
	-- Statistics report includes them.
	attribute altera_attribute of vb_s1 : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of vb_s2 : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";

	attribute altera_attribute of req_sync1_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of req_sync2_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of ack_sync1_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of ack_sync2_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of strobe_sync1_reg : signal is
		"-name SYNCHRONIZER_IDENTIFICATION ""FORCED IF ASYNCHRONOUS""";
	attribute altera_attribute of strobe_sync2_reg : signal is
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

	-- F.3' (2026-05-24): arbiter prefetch strobe sync chain.
	-- bus_request_strobe_in is a clk_sys pulse (combinational on sysCycle)
	-- that fires 2 clk_sys before bus_ack_pulse_in. We sync it into clk_cpu
	-- and edge-detect so the source FSM can dispatch its toggle right
	-- before the sink will fire ack. Three FFs: 2 for metastability,
	-- 1 for clean edge derivation.
	strobe_sync : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			strobe_sync1_reg <= bus_request_strobe_in;
			strobe_sync2_reg <= strobe_sync1_reg;
			strobe_sync3_reg <= strobe_sync2_reg;
		end if;
	end process;

	strobe_edge <= strobe_sync2_reg and (not strobe_sync3_reg);

	-- Milestone B v2 (2026-05-26): vsync (clk_sys) → clk_cpu 3-FF sync
	-- chain + rising-edge detect. Drives the per-frame snapshot of the
	-- wrapping RQ/AK counters, the dwell-max tracker, the sticky activity
	-- flags, and the gap-max tracker. Slow signal (50/60 Hz) — 3-FF level
	-- sync is the canonical CDC pattern for this kind of single-bit edge
	-- (docs/hdl-coding-guidelines/24-cdc-multi-bit.md §3.1).
	vblank_sync : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			vb_s1 <= dbg_vblank_sys_in;
			vb_s2 <= vb_s1;
			vb_s3 <= vb_s2;
		end if;
	end process;

	vb_cpu_rise <= vb_s2 and (not vb_s3);

	cpu_side : process(clk_cpu) begin
		if rising_edge(clk_cpu) then
			if reset = '1' then
				cpu_fsm             <= CPU_IDLE;
				cpu_req_toggle_reg  <= '0';
				cpu_rdy_reg         <= '1';
				cpu_enable_reg      <= '0';
				cpu_req_addr_reg    <= (others => '0');
				cpu_req_addr_hi_reg <= (others => '0');
				cpu_req_do_reg      <= (others => '0');
				cpu_req_we_reg      <= '0';
				cpu_req_vpa_reg     <= '0';
				cpu_req_vda_reg     <= '0';
				bus_di_capture_reg  <= (others => '0');
				-- Milestone B probe counters reset to zero.
				dbg_req_count_reg     <= (others => '0');
				dbg_ack_count_reg     <= (others => '0');
				dbg_vec_count_reg     <= (others => '0');
				-- v2 (Codex Design 3) accumulators + snapshots
				dbg_req_snap_reg      <= (others => '0');
				dbg_ack_snap_reg      <= (others => '0');
				dbg_vec_snap_reg      <= (others => '0');
				wait_dwell_reg        <= (others => '0');
				wait_dwell_max_accum  <= (others => '0');
				wait_dwell_max_snap   <= (others => '0');
				req_seen_accum        <= '0';
				ack_seen_accum        <= '0';
				wait_seen_accum       <= '0';
				dbg_flags_snap        <= (others => '0');
				gap_cur               <= (others => '0');
				gap_max_accum         <= (others => '0');
				gap_max_snap          <= (others => '0');
			else
				cpu_enable_reg <= '0';  -- default deassert each clk_cpu
				-- v2 default: dwell counter resets unless we're in WAIT_ACK.
				-- Overridden in `when CPU_WAIT_ACK` below (last-assignment-wins).
				wait_dwell_reg <= (others => '0');

				-- ----------------------------------------------------------
				-- Milestone B v2 (Codex Design 3) per-vblank snapshot.
				-- ----------------------------------------------------------
				-- PLACED BEFORE THE CASE STATEMENT so any same-clk_cpu FSM
				-- transition (IDLE→PENDING, WAIT_ACK→LATCH) overrides our
				-- carry-forward/clear via last-assignment-wins. This fixes
				-- the Codex v2 review finding 2: if vb_cpu_rise coincides
				-- with an event clk, the case branch's updates take precedence
				-- and the new frame correctly inherits the just-fired event.
				--
				-- The snapshot itself captures the value AS OF this clk_cpu
				-- edge (pre-event). The clears/carry-forward set "defaults for
				-- the new frame"; the case below may override them this cycle.
				--
				-- Note on FL bit assignments: the per-bit assignments below
				-- avoid VHDL-2008 aggregate-with-conditional syntax for
				-- Quartus 17 / GHDL 1.0 compatibility.
				if vb_cpu_rise = '1' then
					dbg_req_snap_reg    <= dbg_req_count_reg;
					dbg_ack_snap_reg    <= dbg_ack_count_reg;
					dbg_vec_snap_reg    <= dbg_vec_count_reg;
					wait_dwell_max_snap <= wait_dwell_max_accum;
					gap_max_snap        <= gap_max_accum;
					-- Pack sticky activity flags into the snap byte:
					--   bit 0 = req_seen
					--   bit 1 = ack_seen
					--   bit 2 = wait_seen
					--   bit 7 = wait_dwell_max_accum saturated to $FFFF
					dbg_flags_snap(6 downto 3) <= "0000";
					dbg_flags_snap(0) <= req_seen_accum;
					dbg_flags_snap(1) <= ack_seen_accum;
					dbg_flags_snap(2) <= wait_seen_accum;
					if wait_dwell_max_accum = x"FFFF" then
						dbg_flags_snap(7) <= '1';
					else
						dbg_flags_snap(7) <= '0';
					end if;
					-- Defaults for the new frame. The case statement (below)
					-- can override these via last-assignment-wins.
					req_seen_accum       <= '0';
					ack_seen_accum       <= '0';
					wait_seen_accum      <= '0';
					-- Carry-forward: a wait or gap that survives the frame
					-- boundary keeps its observable state in the new frame.
					--
					-- WAIT_ACK dwell carry uses (wait_dwell_reg + 1) to match
					-- the "+1 semantic" of the case CPU_WAIT_ACK compare. If
					-- we carried the bare dwell_reg, the case's compare
					-- `(dwell_reg + 1) > max_accum` would land at equality on
					-- vblank clk and decline to override — leaving max_accum
					-- 1 unit low until the next case-firing clk. Matching the
					-- +1 here makes the boundary cycle a no-op for max.
					if wait_dwell_reg /= x"FFFF" then
						wait_dwell_max_accum <= wait_dwell_reg + 1;
					else
						wait_dwell_max_accum <= x"FFFF";
					end if;
					-- Gap carry: the case's IDLE→PENDING uses `gap_cur + 1`,
					-- so carry-forward should pre-load that too — same reason
					-- as WD above. If we're not in IDLE→PENDING on the
					-- boundary clk, the bare gap_cur is fine; defensive +1
					-- here would over-bump. Stick with gap_cur and rely on
					-- the next IDLE→PENDING (which uses gap_cur+1>max) to
					-- correct any 1-unit dent.
					gap_max_accum        <= gap_cur;
				end if;

				case cpu_fsm is
					when CPU_IDLE =>
						cpu_rdy_reg <= '1';
						-- F.3' Path B v2 (2026-05-24): sustain cpu_enable while
						-- IDLE so multi-cycle P65C816 ops (16-bit reads, BCD,
						-- native-mode interrupts) have enough EN=1 cycles to
						-- complete. The CPU self-stalls via cpu_rdy=0 when the
						-- next request fires below (IDLE→PENDING transition).
						cpu_enable_reg <= '1';
						if cpu_vpa_in = '1' or cpu_vda_in = '1' then
							-- Stage 1: latch payload immediately, stall the
							-- CPU. The payload crosses clk_cpu→clk_sys
							-- unsynchronized; the payload-stable-hold rule
							-- guarantees it doesn't change again until ack
							-- returns (anti-pattern entry 60).
							cpu_req_addr_reg    <= cpu_addr_in;
							cpu_req_addr_hi_reg <= cpu_addr_hi_in;
							cpu_req_do_reg      <= cpu_do_in;
							cpu_req_we_reg      <= cpu_we_in;
							cpu_req_vpa_reg     <= cpu_vpa_in;
							cpu_req_vda_reg     <= cpu_vda_in;
							cpu_rdy_reg         <= '0';
							cpu_enable_reg      <= '0';  -- override sustain when stalling
							cpu_fsm             <= CPU_REQ_PENDING;
							-- Milestone B v2: WRAPPING req-count + sticky req_seen
							-- flag + gap_cur bump. Wrap (mod 65536) instead of
							-- saturating so RQ-snap deltas remain meaningful past
							-- the first vblank.
							dbg_req_count_reg <= dbg_req_count_reg + 1;
							req_seen_accum    <= '1';
							if gap_cur /= x"FF" then
								gap_cur <= gap_cur + 1;
								if gap_cur + 1 > gap_max_accum then
									gap_max_accum <= gap_cur + 1;
								end if;
							end if;
						end if;
					when CPU_REQ_PENDING =>
						-- Stage 2: hold the captured payload until the
						-- arbiter signals "I have a CPU slot in 2 clk_sys."
						-- Toggle req at that edge so the sink-side sees it
						-- right before bus_ack_pulse_in fires.
						if strobe_edge = '1' then
							cpu_req_toggle_reg <= not cpu_req_toggle_reg;
							cpu_fsm            <= CPU_WAIT_ACK;
							-- Milestone B IRQ-vector-fetch probe: increment
							-- when this REQ_PENDING→WAIT_ACK is dispatching a
							-- read of $00:$FFFE or $00:$FFFF (IRQ vector low /
							-- high). Tracked at strobe_edge (not ack) so the
							-- counter ticks once per dispatched IRQ vector
							-- fetch even if the ack later stalls (race β).
							if cpu_req_addr_hi_reg = x"00"
							   and cpu_req_addr_reg(15 downto 1) = "111111111111111"
							   and cpu_req_we_reg = '0' then
								if dbg_vec_count_reg /= x"FF" then
									dbg_vec_count_reg <= dbg_vec_count_reg + 1;
								end if;
							end if;
						end if;
					when CPU_WAIT_ACK =>
						-- Milestone B v2: WAIT_ACK dwell tracker — increment the
						-- live dwell counter and the sticky wait_seen flag every
						-- clk_cpu we spend here. Saturates at $FFFF so a hung
						-- WAIT_ACK is clearly distinguishable from a healthy
						-- short dwell. The pre-case `wait_dwell_reg <= 0`
						-- default is overridden here (last-assignment-wins);
						-- in all other states, dwell_reg returns to 0.
						--
						-- Off-by-one fix (Codex v2 review, 2026-05-26): we use
						-- `wait_dwell_reg + 1` for both the SCHEDULED next value
						-- AND the max compare/capture so a 1-clk WAIT_ACK reports
						-- as 1, not 0. The semantic "dwell counted in this state
						-- so far" includes the current clk_cpu.
						if wait_dwell_reg /= x"FFFF" then
							wait_dwell_reg <= wait_dwell_reg + 1;
							if (wait_dwell_reg + 1) > wait_dwell_max_accum then
								wait_dwell_max_accum <= wait_dwell_reg + 1;
							end if;
						end if;
						-- (saturated branch: dwell_reg stays at $FFFF; max
						-- already pegged to $FFFF too, no update needed)
						wait_seen_accum <= '1';

						-- Ack observed when synced toggle catches up to req.
						if ack_sync2_reg = cpu_req_toggle_reg then
							-- Capture read data. The bus_di_in net crosses
							-- unsynchronized — safe here because the sink
							-- has held it stable since the cycle the arbiter
							-- pulsed bus_ack_pulse_in (the sink registers
							-- bus_di_in into bus_di_reg on that cycle).
							bus_di_capture_reg <= bus_di_reg;
							cpu_rdy_reg        <= '1';
							-- Fire cpu_enable_out for exactly this clk_cpu
							-- cycle. rdy goes '1' on the same edge, so the
							-- CPU sees EN=RDY AND CE both true simultaneously.
							cpu_enable_reg     <= '1';
							cpu_fsm            <= CPU_LATCH;
							-- Milestone B v2: WRAPPING ack-count + sticky
							-- ack_seen flag + gap_cur decrement. The bridge is
							-- structurally one-outstanding, so gap_cur should
							-- never exceed 1 in healthy operation; if GM>1
							-- ever shows up it implies an FSM invariant
							-- violation worth investigating.
							dbg_ack_count_reg <= dbg_ack_count_reg + 1;
							ack_seen_accum    <= '1';
							if gap_cur /= x"00" then
								gap_cur <= gap_cur - 1;
							end if;
						end if;
					when CPU_LATCH =>
						-- One clk_cpu where rdy=1, en=1, fsm=LATCH so the
						-- combinational gate (keyed on fsm=IDLE) stays
						-- inactive and the CPU latches the fresh di. Then
						-- back to IDLE with regs still 1; the gate handles
						-- stalling on any new vpa/vda the CPU now asserts.
						cpu_rdy_reg    <= '1';
						cpu_enable_reg <= '1';
						cpu_fsm        <= CPU_IDLE;
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
	bus_addr_out    <= cpu_req_addr_reg    when EFF_BRIDGE_ACTIVE = '1' else cpu_addr_in;
	bus_addr_hi_out <= cpu_req_addr_hi_reg when EFF_BRIDGE_ACTIVE = '1' else cpu_addr_hi_in;
	bus_do_out      <= cpu_req_do_reg      when EFF_BRIDGE_ACTIVE = '1' else cpu_do_in;
	-- v13 reverted (2026-05-24): gating bus_we_out by bus_request_pending_reg
	-- broke RAM writes during KERNAL boot (sync-chain gap dropped we strobe
	-- before CYCLE_CPUC). Phantom-write fix now applied at cs_cia1 in
	-- fpga64_buslogic.vhd by gating with bus_vpa/vda OR. Memory:
	-- [[v13-bus-we-gate-broke-boot-2026-05-24]].
	-- v13f reverted (2026-05-25): gating ALL bus_*_out signals coherently by
	-- request_pending wedged CPU at PC=$FCD1 from boot — black screen, no
	-- progress. Hypothesis: synthesis routes the extra muxes in a way that
	-- creates a setup-time race on bus_di_in capture by the sink at
	-- enableCpu_816 edge, when bus_addr_out has just changed. Reverting
	-- bus_*_out gating; v13d's CIA1 partial fix remains the working state.
	bus_we_out      <= cpu_req_we_reg      when EFF_BRIDGE_ACTIVE = '1' else cpu_we_in;
	bus_vpa_out     <= (cpu_req_vpa_reg and bus_request_pending_reg) when EFF_BRIDGE_ACTIVE = '1' else cpu_vpa_in;
	bus_vda_out     <= (cpu_req_vda_reg and bus_request_pending_reg) when EFF_BRIDGE_ACTIVE = '1' else cpu_vda_in;

	-- CPU side: when BRIDGE_ACTIVE='1', the handshake supplies di/rdy.
	-- When BRIDGE_ACTIVE='0', the bus_di_in / '1' passthrough preserves
	-- baseline behavior bit-for-bit. CACHE_ACTIVE='1' lets the cache win
	-- for ZP+stack reads, but only after the bridge path is in use.
	cpu_di_out <= cache_dout         when CACHE_ACTIVE  = '1' and cache_hit = '1' and cache_valid_dout = '1' else
	              bus_di_capture_reg when EFF_BRIDGE_ACTIVE = '1' else
	              bus_di_in;
	-- v5 (2026-05-24): combinational stall gate. When EFF_BRIDGE_ACTIVE='1'
	-- and bridge is in CPU_IDLE state, force rdy=0 AND en=0 the moment CPU
	-- asserts vpa or vda. This prevents the CPU from latching stale
	-- bus_di_capture_reg when transitioning from the previous request's
	-- WAIT_ACK match into the next request's bus cycle. Without this gate,
	-- the registered cpu_rdy_reg / cpu_enable_reg are still '1' at the edge
	-- the CPU advances and presents new vpa/vda — CPU samples rdy=1 en=1
	-- and latches whatever stale value cpu_di_out is currently showing.
	-- During internal cycles (vpa=0 vda=0), the gate is transparent so the
	-- CPU advances multi-cycle ops freely (this was v2's sustain-en intent).
	cpu_rdy_out <= '0' when EFF_BRIDGE_ACTIVE = '1'
	                   and cpu_fsm = CPU_IDLE
	                   and (cpu_vpa_in = '1' or cpu_vda_in = '1')
	              else cpu_rdy_reg when EFF_BRIDGE_ACTIVE = '1'
	              else '1';

	-- F.3' enable CDC: when MCP path active, drive CPU enable from the
	-- bridge's WAIT_ACK->IDLE transition (aligned with rdy release). When
	-- inactive (passthrough), pass through the legacy enableCpu_816 supplied
	-- via bus_ack_pulse_in -- preserves baseline behavior bit-for-bit.
	cpu_enable_out <= '0' when EFF_BRIDGE_ACTIVE = '1'
	                      and cpu_fsm = CPU_IDLE
	                      and (cpu_vpa_in = '1' or cpu_vda_in = '1')
	                 else cpu_enable_reg when EFF_BRIDGE_ACTIVE = '1'
	                 else bus_ack_pulse_in;

	------------------------------------------------------------------
	-- Milestone B v2 probe outputs (clk_cpu domain).
	--
	-- All RQ/AK/WD/FL/GM outputs are driven from per-vblank SNAPSHOT
	-- registers (not live counters). The snapshots are held stable for
	-- a full frame, so the c64.sv 2-FF sync of these outputs is valid
	-- — the live-counter multi-bit tearing problem Codex flagged in v1
	-- is fixed by source-domain snapshotting (docs/hdl-coding-guidelines
	-- /24-cdc-multi-bit.md §3.3).
	--
	-- fsm_state and last_bus_di are still passed through "live" because
	-- they are observability hints, not race detectors — occasional
	-- skew on those is acceptable.
	------------------------------------------------------------------
	dbg_fsm_state <= x"0" when cpu_fsm = CPU_IDLE        else
	                 x"1" when cpu_fsm = CPU_REQ_PENDING else
	                 x"2" when cpu_fsm = CPU_WAIT_ACK    else
	                 x"3";  -- CPU_LATCH
	dbg_last_bus_di         <= bus_di_capture_reg;
	dbg_req_count           <= dbg_req_snap_reg;
	dbg_ack_count           <= dbg_ack_snap_reg;
	-- v2 fix (Codex review finding 1): drive VF from snapshot so the
	-- multi-bit value crossing to clk_sys is frame-stable, like RQ/AK.
	dbg_irq_vec_fetch_count <= dbg_vec_snap_reg;
	dbg_wait_dwell_max      <= wait_dwell_max_snap;
	dbg_activity_flags      <= dbg_flags_snap;
	dbg_gap_max             <= gap_max_snap;

end architecture;
