//
// sdram_pm.v — page-mode SDRAM controller (Build C HIT/MISS, 2026-05-25)
//
// History:
//   Build A: original page-mode FSM. Wedged C64 at PC=$00:$0D62 — bench
//            and HW debug never pinned the cause. Reverted to Build B.
//   Build B: identical to baseline sdram.v except for module name and
//            the added `ready`/`data_valid` outputs. Cycle = 8 clk64
//            (later 6 clk64 with v6 q=5→0 shortcut). No row tracking.
//   Build C (this file, 2026-05-25): re-introduces page-mode HIT path
//            with a structurally simpler design than Build A. Row/bank
//            registers are tracked; HIT skips ACTIVATE and samples at
//            q=2 (CAS_LATENCY) instead of q=5; refresh invalidates the
//            open row. MISS path is bit-identical to Build B (q=0..5).
//
// HIT/MISS decision is private to this controller — no new port surface;
// the existing ports (sd_*, ready, data_valid, addr, ce, we, din, dout,
// refresh) are preserved verbatim so c64.sv's named-port instantiation
// remains unchanged. fpga64_sid_iec.vhd mirrors the same row/bank
// tracking against the bus-side address to predict HIT vs MISS for its
// busy-counter preload (design doc §3.2 fallback path: predictor lives
// in the arbiter, not as a new sdram_pm port).
//
// Design reference: docs/milestone_a_buildc_design.md §2 + §4.
// Wedge-mitigation reference: project_alt_fire_r_dead_on_buildB_2026_05_23.md
// (alt_fire_r remains registered & hard-gated-off until system-level
// validation; this file only addresses the controller-side primitive.)
//
// Original GPLv3 SDRAM controller by Till Harbaum.

module sdram_pm (

	// interface to the MT48LC16M16 chip
	output reg [12:0]	sd_addr,    // 13 bit multiplexed address bus
	inout  reg [15:0]	sd_data,
	output reg [ 1:0]	sd_ba,      // two banks
	output 				sd_cs,      // a single chip select
	output 				sd_we,      // write enable
	output 				sd_ras,     // row address select
	output 				sd_cas,     // columns address select
	output 				sd_clk,
	output 		[1:0]	sd_dqm,

	// cpu/chipset interface
	input 		 		init,			// init signal after FPGA config to initialize RAM
	input 		 		clk,			// sdram is accessed at up to 128MHz

	input      [24:0] addr,       // 25 bit byte address
	input      [ 7:0] din,
	output     [ 7:0]	dout,
	output     [ 7:0]	dout_hi,    // high byte of last SDRAM read (bt-independent)
	output     [ 7:0]	dout_lo,    // low byte of last SDRAM read (bt-independent)
	output     [ 7:0]	dout_reu,   // high byte latched only for REU reads (bt=1, read)

	input 		 		refresh,    // refresh cycle
	input 		 		ce,         // cpu/chipset access
	input 		 		we,         // cpu/chipset requests write
	// Option (b) gate (Milestone A, 2026-05-26): '1' = current access is in
	// the SCPU SuperRAM region (driven by scpu_fast_path in fpga64_sid_iec).
	// HIT path (with A10=0 / no auto-precharge) only engages when this is
	// asserted; bank-$00 / cart_addr / REU traffic always takes the MISS
	// path with A10=1 (auto-precharge ON, row closes after burst) which is
	// bit-identical to the Build B baseline (d564dea). Default '0' keeps
	// the controller behaviour conservative if the port is left unwired.
	input 		 		fast_path,
	output 				ready,      // 1 = idle, safe to assert new ce edge (for future backpressure)
	// Step 6 Phase 6a (2026-05-20): "dout_r is fresh" handshake for the
	// arbiter. Asserts post-edge of the sample edge (q == STATE_READ),
	// clears at the next ce-edge. Level signal — single-flop sync on
	// the consumer side is sufficient since it stays high for several
	// clk64 between sample and the next cycle start.
	output reg          data_valid
);

// no burst configured
localparam RASCAS_DELAY   = 3'd2;   // tRCD>=20ns -> 2 cycles@64MHz
localparam BURST_LENGTH   = 3'b000; // 000=none, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------
//
// MISS path (q sequence 0,1,2,3,4,5,0 — 6 clk64, identical to Build B
// with v6 shortcut):
//   q=0  ce-edge issues ACTIVATE
//   q=2  STATE_CMD_CONT issues READ/WRITE
//   q=5  STATE_READ samples dout, ready rises next edge
//
// HIT path (q sequence 0,1,2,0 — 3 clk64). HIT means current request
// targets the same bank+row as the last access AND the open row has not
// been invalidated by reset or a refresh. Auto-precharge bits in the
// existing CMD_READ/CMD_WRITE address pattern (2'b10) keep the row
// OPEN — that pattern is already in place for Build B, so HIT can re-use
// the same READ/WRITE sd_addr layout with no extra precharge work.
//   q=0  ce-edge issues READ/WRITE directly (no ACTIVATE)
//   q=2  STATE_READ_HIT samples dout, ready rises next edge
//
// Auto-precharge handling: see sd_addr assignment at the bottom of the
// main always block — the {~bt&wr, bt&wr, 2'b10, caddr} pattern leaves
// A10=0 on the READ/WRITE command (the 2'b10 substring covers A11..A10),
// so the row stays open after the burst, which is the HIT precondition.

localparam STATE_CMD_START   = 3'd0;   // state in which a new command can be started
localparam STATE_CMD_CONT    = STATE_CMD_START  + RASCAS_DELAY;   // = 2 — MISS READ/WRITE
localparam STATE_READ        = STATE_CMD_CONT + CAS_LATENCY + 1'd1; // = 5 — MISS sample edge
// HIT sample edge — was CAS_LATENCY (=2) on the first cut; Codex 2026-05-26
// flagged that as missing the +1 safety margin the MISS path inherited from
// Till Harbaum's baseline (STATE_READ = STATE_CMD_CONT + CAS_LATENCY + 1).
// At 64MHz with sd_clk via altddio_out the SDRAM sees commands ~half a clk64
// later than the FPGA regs update; sampling at q=2 risks landing on/before
// DQ-valid. Bump to CAS_LATENCY+1=3 to mirror MISS's margin. HIT cycle goes
// from 3 → 4 clk64 — still well under MISS=6.
localparam STATE_READ_HIT    = CAS_LATENCY + 1'd1;                // = 3 — HIT sample edge
localparam STATE_LAST        = 3'd7;   // last state in cycle (MISS slow path retains q=7)

reg [2:0] q /* synthesis noprune */;
reg last_ce, last_refresh;
// Forward declaration of `reset` so SystemVerilog-strict simulators (Questa
// with -sv) accept the q-block. Quartus and Verilator accept either ordering;
// kept the initial value below at its original location.
reg [4:0] reset;

// ---------------------------------------------------------------------
// ----------------- Build C: page-mode HIT detection ------------------
// ---------------------------------------------------------------------
//
// Row/bank tracking registers. Address slice matches the sd_ba / sd_addr
// assignments inside the main always block:
//   bank = addr[22:21]
//   row  = addr[20:8]
//   col  = {addr[23], addr[7:0]}  (column also depends on bank-top bit)
//
// last_row_valid is set whenever a successful ACTIVATE is issued (i.e.
// when the MISS path fires) and cleared by reset or refresh. It is NOT
// updated on HIT (the row was already valid). It is also NOT updated
// while we are mid-cycle on a different access — the in_flight test is
// implicit because ce-edge requires `ce && !last_ce`, and `last_ce`
// stays high while ce stays high.
//
// cycle_is_hit is latched at the ce-edge. It selects which q sequence
// the cycle takes. Once latched it must not change until ready rises
// (i.e. until q wraps to 0 and last_ce drops with ce).
reg [12:0] last_row;
reg [ 1:0] last_bank;
reg        last_row_valid;
reg        cycle_is_hit;       // valid while q != 0
// Option (a) PRECHARGE FSM (2026-05-26): latched at ce-edge. '1' means
// the current MISS cycle must issue CMD_PRECHARGE-ALL first (because
// some bank had a row left open by a prior fast_path=1 access) before
// CMD_ACTIVE on the target bank. This adds ~2 clk64 to the cycle but
// is required for SDRAM-spec safety — see Codex Risk 2 in
// memory/project_milestone_a_option_b_codex_falsified.md.
reg        cycle_needs_precharge;
// Latched row address for the q=2 ACTIVE on conflict MISS. (sd_ba is
// already latched at ce-edge — see line 307 — so the bank is preserved
// implicitly; we just need the row bits captured because the live
// `addr` may change between ce-edge and q=2.)
reg [12:0] cycle_row_latched;

// Refresh sub-state. When refresh fires with last_row_valid=1, we
// issue CMD_PRECHARGE-ALL first, wait tRP, then issue CMD_AUTO_REFRESH.
// refresh_pending=1 means we're between those two commands;
// refresh_wait counts down the tRP delay. CPU ce-edges are assumed not
// to fire while refresh_pending=1 (refresh is scheduled by the upstream
// arbiter to fall in an idle cycle window — see
// fpga64_sid_iec.vhd:1568).
reg        refresh_pending;
reg [1:0]  refresh_wait;

// HIT detection is purely combinational against the live `addr` — read
// only at the ce-edge (i.e. when `ce && !last_ce` fires). DO NOT use
// this elsewhere; outside the ce-edge `addr` may belong to a future
// request whose row register is being updated this cycle.
//
// Option (b) gate: HIT only fires when fast_path is asserted (SuperRAM
// access). bank-$00 / cart / REU traffic forces row_hit=0 so they always
// take the MISS path with auto-precharge ON (Build B-equivalent).
wire row_hit = fast_path
            && last_row_valid
            && (addr[22:21] == last_bank)
            && (addr[20:8]  == last_row);

// Option (a) conflict detection. With the single-bank-open invariant
// (any non-HIT MISS issues PRECHARGE-ALL first when something is open),
// this fires whenever a non-HIT MISS lands while last_row_valid=1. The
// cost is +2 clk64 per non-HIT MISS while a row is tracked open.
wire need_precharge_now = last_row_valid && !row_hit;

always @(posedge clk) begin
	last_ce <= ce;
	last_refresh <= refresh;

	// start a new cycle in rising edge of ce
	if(ce && !last_ce) begin
		q                     <= 3'd1;
		cycle_is_hit          <= row_hit;
		cycle_needs_precharge <= need_precharge_now;
		cycle_row_latched     <= addr[20:8];
	end
	if(q || reset) q <= q + 3'd1;
	// V6 (2026-05-23): MISS cycle-shorten early-exit. After sample at q=5
	// (STATE_READ), force q back to 0 next clock. Skips q=6/q=7 padding,
	// trims MISS cycle from 8 → 6 clk64. Must be the LAST q assignment
	// to win the NBA race vs the increment.
	// Option (a): for conflict-MISS the sample is at q=7, so DO NOT wrap
	// at q=5 in that case (let q advance through 6 and 7 to sample).
	if (q == 3'd5 && !reset && !cycle_needs_precharge && !cycle_is_hit) q <= 3'd0;
	// Conflict-MISS wrap at q=7 (sample edge).
	if (q == 3'd7 && !reset && cycle_needs_precharge && !cycle_is_hit) q <= 3'd0;
	// Build C HIT early-exit: after sample at q=2 on the HIT path, force
	// q back to 0 next clock. Skips q=3/4/5 — trims HIT cycle to 3 clk64.
	// Guarded by cycle_is_hit to avoid clobbering the MISS path's q=2
	// READ/WRITE issue edge.
	if (cycle_is_hit && q == STATE_READ_HIT && !reset) q <= 3'd0;

	// Row tracking lifecycle.
	// NOTE: refresh_pending / refresh_wait are reset in main_clk_block's
	// reset branch (lines 358+), not here — Quartus rejects multi-driver
	// regs from two always-blocks. Codex falsification 2026-05-26 caught
	// this before silicon.
	if (reset) begin
		last_row_valid <= 1'b0;
	end else begin
		// Refresh edge: clear the tracker BEFORE issuing AUTO_REFRESH
		// (handled at the refresh handler below — for Option (a), if
		// last_row_valid=1 we first PRECHARGE-ALL, then AUTO_REFRESH).
		if (refresh && !last_refresh) begin
			last_row_valid <= 1'b0;
		end
		// On a MISS ce-edge the controller will ACTIVATE the new row.
		// Two cases:
		//   - fast_path=1 (SuperRAM MISS): record row so the next access
		//     can HIT. A10=0 keeps the row open after burst — consistent
		//     with the predictor's last_row_valid=1. Whether or not
		//     conflict-MISS fired first (PRECHARGE-ALL closed prior rows
		//     before this ACTIVE), the NEW row is the only one open.
		//   - fast_path=0 (bank-$00 / cart / REU MISS): A10=1 closes the
		//     row via auto-precharge. INVALIDATE last_row_valid so a
		//     subsequent SuperRAM access doesn't see a phantom open row
		//     that the physical SDRAM no longer has.
		// On a HIT ce-edge we don't update (row already valid, bank/row
		// unchanged).
		if (ce && !last_ce && !row_hit) begin
			if (fast_path) begin
				last_bank      <= addr[22:21];
				last_row       <= addr[20:8];
				last_row_valid <= 1'b1;
			end else begin
				last_row_valid <= 1'b0;
			end
		end
	end
end

// Backpressure for future bus arbitration.
assign ready = (q == 3'd0) && !reset;

// Step 6 Phase 6a (2026-05-20): default initialisation for data_valid.
// Set to 1 in the always block at the q == STATE_READ sample edge; cleared
// at ce-edge when a new cycle starts. Stays high between cycles so the
// clk32-domain sync consumer always sees a stable level.
initial data_valid = 1'b0;

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 clkref cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
initial reset = 5'h1f;

always @(posedge clk) begin
	if(init)	reset <= 5'h1f;
	else if((q == STATE_LAST) && (reset != 0)) reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [2:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = 0;
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];
assign sd_dqm = sd_addr[12:11];

reg bt;
reg [15:0] dout_r;

assign dout = bt ? dout_r[15:8] : dout_r[7:0];
assign dout_hi = dout_r[15:8];  // always high byte, no bt dependency
assign dout_lo = dout_r[7:0];   // always low byte, no bt dependency

// REU data latch: captures high byte when a read completes for an address
// with bit[24]=1 (REU/SuperRAM region). Updated inside the main always block
// where 'wr' is accessible. Stays latched until the next REU read completes.
reg [7:0] dout_reu_r;
assign dout_reu = dout_reu_r;

// Named-block alias so the bench-side compilers (Questa without -sv) accept
// the declarations on lines below. Quartus/Verilator accept either form.
always @(posedge clk) begin : main_clk_block
	reg [8:0] caddr;
	reg [7:0] wrdata;
	reg       wr;
	// Latched fast_path for the MISS path (used at q=2 to select A10).
	// Captured at the same ce-edge as bt/wr/caddr.
	reg       miss_fastpath;

	sd_cmd  <= CMD_NOP;
	sd_data <= 16'bZ;

	// MISS sample edge — q=5 (STATE_READ) for non-conflict MISS.
	if(q == STATE_READ && !cycle_is_hit && !cycle_needs_precharge) begin
		dout_r <= sd_data;
		if(bt && !wr) dout_reu_r <= sd_data[15:8];
		// Step 6 Phase 6a: signal "dout_r is fresh" to the arbiter.
		data_valid <= 1'b1;
	end
	// Conflict-MISS sample edge — q=7. Same shape as above; +2 clk64
	// later because the PRECHARGE-ALL + tRP + ACTIVE prologue shifted
	// the READ/WRITE to q=4 instead of q=2.
	if(q == 3'd7 && !cycle_is_hit && cycle_needs_precharge) begin
		dout_r <= sd_data;
		if(bt && !wr) dout_reu_r <= sd_data[15:8];
		data_valid <= 1'b1;
	end
	// HIT sample edge — q=3 (STATE_READ_HIT = CAS_LATENCY + 1). Mirrors
	// the +1 safety margin the MISS path inherits from Till Harbaum's
	// baseline (Codex 2026-05-26 falsification: sampling at q=2 risks
	// landing on/before DQ-valid because sd_clk is generated via
	// altddio_out — chip-side cycle skew is ~0.5 clk64).
	if(q == STATE_READ_HIT && cycle_is_hit) begin
		dout_r <= sd_data;
		if(bt && !wr) dout_reu_r <= sd_data[15:8];
		data_valid <= 1'b1;
	end

	if(reset) begin
		sd_ba <= 0;
		data_valid <= 1'b0;
		// Reset refresh sub-state here (Codex 2026-05-26: single-driver
		// rule — refresh_pending / refresh_wait are otherwise assigned
		// from this always-block only, never block 1).
		refresh_pending <= 1'b0;
		refresh_wait    <= 2'b00;
		if(q == STATE_CMD_START) begin
			if(reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;
			end
			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end
		end
	end
	else begin
		// Refresh handler — Option (a) (2026-05-26).
		//
		// If a row is currently tracked open (last_row_valid=1), the
		// SDRAM spec forbids AUTO_REFRESH while any bank is open. Issue
		// CMD_PRECHARGE-ALL first (A10=1 selects all-bank precharge),
		// set refresh_pending + refresh_wait, and the timer below will
		// emit CMD_AUTO_REFRESH after tRP elapses.
		//
		// If no row is tracked open, fire AUTO_REFRESH directly (same
		// as Build B baseline).
		if(refresh && !last_refresh) begin
			if (last_row_valid) begin
				sd_cmd          <= CMD_PRECHARGE;
				// A10=1 (sd_addr[10]) = precharge ALL banks. Other bits
				// don't care for precharge.
				sd_addr         <= 13'b0010000000000;
				refresh_pending <= 1'b1;
				refresh_wait    <= 2'd2;   // tRP = 2 clk64 wait
			end else begin
				sd_cmd <= CMD_AUTO_REFRESH;
			end
		end
		// Deferred AUTO_REFRESH issue after PRECHARGE-ALL + tRP wait.
		// refresh_wait counts down to 0; on the 0-edge issue the actual
		// AUTO_REFRESH command and clear refresh_pending.
		else if (refresh_pending) begin
			if (refresh_wait == 2'd0) begin
				sd_cmd          <= CMD_AUTO_REFRESH;
				refresh_pending <= 1'b0;
			end else begin
				refresh_wait <= refresh_wait - 1'b1;
			end
		end

		if(ce && !last_ce) begin
			// Common bookkeeping for both HIT and MISS — latch bank top
			// bit (bt), write enable, wrdata, and the column address.
			// These are needed by both paths' READ/WRITE issue.
			sd_ba   <= addr[22:21];
			caddr   <= {addr[23], addr[7:0]};
			bt      <= addr[24];
			wr      <= we;
			wrdata  <= din;
			miss_fastpath <= fast_path;
			// Step 6 Phase 6a: new cycle in flight — data_valid drops
			// until the sample edge fires.
			data_valid <= 1'b0;

			if (row_hit) begin
				// HIT path — skip ACTIVATE, issue READ/WRITE immediately
				// with the column address.
				//
				// Auto-precharge fix (2026-05-26): the concat bit layout is
				// {sd_addr[12], sd_addr[11], sd_addr[10], sd_addr[9],
				//  sd_addr[8], sd_addr[7:0]}, so the SECOND-position bit of
				// the {dqm, dqm, A10, A9, A8, col_lo} pattern lives in
				// sd_addr[10] = A10 (the auto-precharge bit). The original
				// code used `2'b10` here which set A10=1 = AUTO-PRECHARGE
				// ENABLED — the row closed immediately after every burst,
				// defeating the HIT optimisation entirely. Use `2'b00` so
				// A10=0 = row stays open. (Inline comment was wrong about
				// A10's bit position. See session_handoff 2026-05-25 §0.)
				if (we) sd_data <= {din, din};
				sd_cmd  <= we ? CMD_WRITE : CMD_READ;
				sd_addr <= {~addr[24] & we, addr[24] & we, 2'b00,
				            addr[23], addr[7:0]};
			end else if (need_precharge_now) begin
				// Conflict MISS — Option (a) PRECHARGE-before-ACTIVATE
				// (2026-05-26). Open row tracked → must close before
				// activating the new bank+row. Issue CMD_PRECHARGE-ALL
				// (A10=1) here at q=0; ACTIVE will fire at q=2; R/W at
				// q=4; sample at q=7.
				sd_cmd  <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;  // A10=1 all-bank precharge
			end else begin
				// MISS path (no conflict) — ACTIVATE the new row;
				// READ/WRITE follows at STATE_CMD_CONT (q=2).
				sd_cmd  <= CMD_ACTIVE;
				sd_addr <= addr[20:8];
			end
		end
		// MISS READ/WRITE issue edge — q=2. Suppressed on the HIT path
		// because cycle_is_hit forces q to wrap from 2→0 (via the
		// always-block above), and because the HIT branch already issued
		// READ/WRITE at q=0. Without this guard the MISS-q=2 branch
		// would overwrite the HIT sd_data load with a stale wrdata.
		if(q == STATE_CMD_CONT && !cycle_is_hit && !cycle_needs_precharge) begin
			if(wr) sd_data <= {wrdata, wrdata};
			sd_cmd  <= wr ? CMD_WRITE : CMD_READ;
			// MISS A10 (auto-precharge) is conditional on the latched
			// fast_path: SuperRAM MISS uses A10=0 (row stays open so the
			// next access can HIT); bank-$00/cart/REU MISS uses A10=1
			// (row closes — preserves Build B baseline behaviour and
			// avoids cross-class row-conflict on bank-$00 traffic).
			sd_addr <= {~bt & wr, bt & wr,
			            miss_fastpath ? 1'b0 : 1'b1, 1'b0,
			            caddr};
		end
		// Conflict-MISS ACTIVATE — fired at q=2 (after PRECHARGE-ALL
		// at q=0 and 2-clk64 tRP wait at q=1).
		if(q == STATE_CMD_CONT && cycle_needs_precharge) begin
			sd_cmd  <= CMD_ACTIVE;
			sd_addr <= cycle_row_latched;
		end
		// Conflict-MISS READ/WRITE — fired at q=4 (2-clk64 tRCD after
		// the ACTIVATE at q=2).
		if(q == 3'd4 && cycle_needs_precharge) begin
			if(wr) sd_data <= {wrdata, wrdata};
			sd_cmd  <= wr ? CMD_WRITE : CMD_READ;
			// Same A10 conditional as the non-conflict path.
			sd_addr <= {~bt & wr, bt & wr,
			            miss_fastpath ? 1'b0 : 1'b1, 1'b0,
			            caddr};
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(sd_clk),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
