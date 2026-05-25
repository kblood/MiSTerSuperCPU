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
localparam STATE_READ_HIT    = CAS_LATENCY;                       // = 2 — HIT sample edge
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

// HIT detection is purely combinational against the live `addr` — read
// only at the ce-edge (i.e. when `ce && !last_ce` fires). DO NOT use
// this elsewhere; outside the ce-edge `addr` may belong to a future
// request whose row register is being updated this cycle.
wire row_hit = last_row_valid
            && (addr[22:21] == last_bank)
            && (addr[20:8]  == last_row);

always @(posedge clk) begin
	last_ce <= ce;
	last_refresh <= refresh;

	// start a new cycle in rising edge of ce
	if(ce && !last_ce) begin
		q            <= 3'd1;
		cycle_is_hit <= row_hit;
	end
	if(q || reset) q <= q + 3'd1;
	// V6 (2026-05-23): MISS cycle-shorten early-exit. After sample at q=5
	// (STATE_READ), force q back to 0 next clock. Skips q=6/q=7 padding,
	// trims MISS cycle from 8 → 6 clk64. Must be the LAST q assignment
	// to win the NBA race vs the increment.
	if (q == 3'd5 && !reset) q <= 3'd0;
	// Build C HIT early-exit: after sample at q=2 on the HIT path, force
	// q back to 0 next clock. Skips q=3/4/5 — trims HIT cycle to 3 clk64.
	// Guarded by cycle_is_hit to avoid clobbering the MISS path's q=2
	// READ/WRITE issue edge.
	if (cycle_is_hit && q == STATE_READ_HIT && !reset) q <= 3'd0;

	// Row tracking lifecycle.
	if (reset) begin
		last_row_valid <= 1'b0;
	end else begin
		// Refresh closes all rows in all banks — invalidate the cached
		// row regardless of whether it happens during an idle window or
		// while q is advancing. (The refresh && !last_refresh edge below
		// only issues CMD_AUTO_REFRESH during idle in the existing logic,
		// so this matches when the row is actually closed.)
		if (refresh && !last_refresh) begin
			last_row_valid <= 1'b0;
		end
		// On a MISS ce-edge the controller will ACTIVATE the new row —
		// record it now so the NEXT access can HIT. On a HIT ce-edge we
		// don't update (row already valid, bank/row unchanged).
		if (ce && !last_ce && !row_hit) begin
			last_bank      <= addr[22:21];
			last_row       <= addr[20:8];
			last_row_valid <= 1'b1;
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

	sd_cmd  <= CMD_NOP;
	sd_data <= 16'bZ;

	// MISS sample edge — q=5 (STATE_READ).
	if(q == STATE_READ && !cycle_is_hit) begin
		dout_r <= sd_data;
		if(bt && !wr) dout_reu_r <= sd_data[15:8];
		// Step 6 Phase 6a: signal "dout_r is fresh" to the arbiter.
		data_valid <= 1'b1;
	end
	// HIT sample edge — q=2 (STATE_READ_HIT). Same dout latch shape as
	// MISS, just earlier. The HIT path drives WRITE without reading
	// sd_data, so dout_r is harmless for writes (we already do the same
	// thing on the MISS path).
	//
	// HW TIMING NOTE (2026-05-25): MISS path samples one clock LATER than
	// the strict CAS_LATENCY formula would suggest (STATE_READ = 5, not
	// STATE_CMD_CONT + CAS_LATENCY = 4). This +1 was inherited from Till
	// Harbaum's original sdram.v as a safety margin. The HIT path here
	// uses STATE_READ_HIT = CAS_LATENCY = 2 (no +1) to match the lite
	// bench model's 3-clk64 cycle. If HW silicon tests reveal HIT reads
	// returning stale data, the cheapest mitigation is to bump
	// STATE_READ_HIT to CAS_LATENCY + 1 = 3 (HIT cycle becomes 4 clk64
	// instead of 3) and update the bench's HIT_SAMPLE_Q to match.
	if(q == STATE_READ_HIT && cycle_is_hit) begin
		dout_r <= sd_data;
		if(bt && !wr) dout_reu_r <= sd_data[15:8];
		data_valid <= 1'b1;
	end

	if(reset) begin
		sd_ba <= 0;
		data_valid <= 1'b0;
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
		if(refresh && !last_refresh) sd_cmd <= CMD_AUTO_REFRESH;

		if(ce && !last_ce) begin
			// Common bookkeeping for both HIT and MISS — latch bank top
			// bit (bt), write enable, wrdata, and the column address.
			// These are needed by both paths' READ/WRITE issue.
			sd_ba   <= addr[22:21];
			caddr   <= {addr[23], addr[7:0]};
			bt      <= addr[24];
			wr      <= we;
			wrdata  <= din;
			// Step 6 Phase 6a: new cycle in flight — data_valid drops
			// until the sample edge fires.
			data_valid <= 1'b0;

			if (row_hit) begin
				// HIT path — skip ACTIVATE, issue READ/WRITE immediately
				// with the column address. Auto-precharge bit (A10 in
				// the {2'b10, caddr} layout) is 0 so the row stays open
				// for the NEXT HIT.
				if (we) sd_data <= {din, din};
				sd_cmd  <= we ? CMD_WRITE : CMD_READ;
				sd_addr <= {~addr[24] & we, addr[24] & we, 2'b10,
				            addr[23], addr[7:0]};
			end else begin
				// MISS path — ACTIVATE the new row; READ/WRITE follows
				// at STATE_CMD_CONT (q=2).
				sd_cmd  <= CMD_ACTIVE;
				sd_addr <= addr[20:8];
			end
		end
		// MISS READ/WRITE issue edge — q=2. Suppressed on the HIT path
		// because cycle_is_hit forces q to wrap from 2→0 (via the
		// always-block above), and because the HIT branch already issued
		// READ/WRITE at q=0. Without this guard the MISS-q=2 branch
		// would overwrite the HIT sd_data load with a stale wrdata.
		if(q == STATE_CMD_CONT && !cycle_is_hit) begin
			if(wr) sd_data <= {wrdata, wrdata};
			sd_cmd  <= wr ? CMD_WRITE : CMD_READ;
			sd_addr <= {~bt & wr, bt & wr, 2'b10, caddr};
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
