//
// sdram_pm.v — page-mode SDRAM controller (DRAFT, NOT YET WIRED INTO BUILD)
//
// Based on sdram.v (Till Harbaum, GPLv3). Modifications:
//   * Tracks the currently-open row per bank (4 banks × 13-bit row + valid bit)
//   * On ce rising edge: if requested bank+row matches the open row, skip the
//     ACTIVE phase and issue CMD_READ/WRITE immediately (page-hit fast path)
//   * Drops the auto-precharge bit (sd_addr[10]) from CMD_READ/CMD_WRITE,
//     so rows remain open across accesses
//   * On row-conflict (same bank, different row): issues a per-bank
//     CMD_PRECHARGE, waits tRP, then proceeds through the cold ACTIVE+READ
//     sequence
//   * On refresh: issues CMD_PRECHARGE all-banks (A10=1) before CMD_AUTO_REFRESH
//     and invalidates the row tracker
//
// Latency (clk64 cycles from ce edge to controller idle again):
//   * Cold (bank closed)   : 8 clk64 (matches baseline)
//   * Page hit             : 4 clk64 (50% reduction)
//   * Row conflict         : 9 clk64 (1 cycle worse than baseline; rare in
//                            streaming workloads)
//   * Refresh w/ banks open: PRECHARGE_ALL + tRP + AUTO_REFRESH + tRC
//
// Caveats / TODO before wiring this into the build:
//   * No backpressure (`sdram_ready` output not exposed). External `ce` edge
//     during an in-flight access still hard-restarts the FSM — that part is
//     unchanged from baseline and must be handled by upstream bus arbitration
//     before this controller is safe to use with extra CPU slots (iter 1.5).
//   * tRP at 64 MHz: 1 clk64 = 15.625 ns is on the edge of the Micron
//     MT48LC16M16 spec (tRP = 15 ns). Holds at the nominal -7E grade but
//     might be tight at temperature corners. If marginal, bump tRP wait.
//   * REU `dout_reu` latch path unchanged.
//   * Module name is `sdram` so it can be swapped in/out by renaming files.
//
// Backward-compatible port set: identical to baseline sdram.v.

module sdram (
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
	output     [ 7:0]	dout_hi,    // high byte of last SDRAM read
	output     [ 7:0]	dout_lo,    // low byte of last SDRAM read
	output     [ 7:0]	dout_reu,   // high byte latched only for REU reads

	input 		 		refresh,    // refresh tick (~1 us)
	input 		 		ce,         // cpu/chipset access request (rising edge)
	input 		 		we,         // 1 = write, 0 = read
	output 				ready       // 1 = idle, safe to assert new ce edge
);

localparam RASCAS_DELAY   = 3'd2;   // tRCD >= 20ns -> 2 cycles @ 64MHz
localparam BURST_LENGTH   = 3'b000; // single
localparam ACCESS_TYPE    = 1'b0;   // sequential
localparam CAS_LATENCY    = 3'd2;
localparam OP_MODE        = 2'b00;
localparam NO_WRITE_BURST = 1'b1;

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

// ---------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------
// q is 4-bit to accommodate the conflict path.
//
// Cold path (q=0 idle, ce rising → q sequence):
//   q=1 : CMD_ACTIVE
//   q=2 : NOP (tRCD)
//   q=3 : CMD_READ / CMD_WRITE (no auto-precharge)
//   q=4 : NOP (CAS)
//   q=5 : NOP
//   q=6 : sample dout_r
//   q=7 : NOP, q→0
//
// Hit path:
//   q=1 : CMD_READ / CMD_WRITE (no auto-precharge)
//   q=2 : NOP (CAS)
//   q=3 : NOP
//   q=4 : sample dout_r, then q→0 (skip)
//
// Conflict path:
//   q=1 : CMD_PRECHARGE single-bank (sd_addr[10]=0)
//   q=2 : NOP (tRP)
//   q=3 : CMD_ACTIVE (new row)
//   q=4 : NOP (tRCD)
//   q=5 : CMD_READ / CMD_WRITE
//   q=6 : NOP (CAS)
//   q=7 : NOP
//   q=8 : sample dout_r
//   q=9 : NOP, q→0
//
// Refresh path (q=0 idle, refresh rising):
//   if any row valid:
//     q=1 : CMD_PRECHARGE all (sd_addr[10]=1), clear row_valid
//     q=2 : NOP (tRP)
//     q=3 : CMD_AUTO_REFRESH
//     q=4..8 : NOP (tRC, conservative)
//     q=9 : q→0
//   else:
//     q=1 : CMD_AUTO_REFRESH
//     q=2..6 : NOP
//     q=7 : q→0

localparam ST_IDLE        = 4'd0;

reg [3:0] q /* synthesis noprune */;
reg       last_ce, last_refresh;

// Backpressure: controller is ready for a new ce edge only when q is idle.
// Bus arbiter MUST consult this before asserting ce on consecutive slots,
// otherwise a row-conflict access (9 clk64) can be aborted mid-flight.
assign ready = (q == ST_IDLE) && !reset;

// Path selector latched at ce/refresh edge
reg [2:0] path;   // 0=cold, 1=hit, 2=conflict, 3=refresh_with_pch, 4=refresh_only
localparam P_COLD     = 3'd0;
localparam P_HIT      = 3'd1;
localparam P_CONFLICT = 3'd2;
localparam P_RFSH_PCH = 3'd3;
localparam P_RFSH     = 3'd4;

// Per-bank open-row tracker
reg [12:0] row_open  [0:3];
reg [3:0]  row_valid;

// ---------------------------------------------------------------------
// Startup/reset
// ---------------------------------------------------------------------
initial reset = 5'h1f;
reg [4:0] reset;
always @(posedge clk) begin
	if(init) reset <= 5'h1f;
	else if((q == 4'd9) && (reset != 0)) reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// Command encoding
// ---------------------------------------------------------------------
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [2:0] sd_cmd;

assign sd_cs  = 0;
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];
assign sd_dqm = sd_addr[12:11];

reg bt;
reg [15:0] dout_r;
assign dout    = bt ? dout_r[15:8] : dout_r[7:0];
assign dout_hi = dout_r[15:8];
assign dout_lo = dout_r[7:0];

reg [7:0] dout_reu_r;
assign dout_reu = dout_reu_r;

// ---------------------------------------------------------------------
// Page-hit / conflict detect (combinational, evaluated on ce edge)
// ---------------------------------------------------------------------
wire [1:0]  req_bank = addr[22:21];
wire [12:0] req_row  = addr[20:8];
wire        bank_valid_now = row_valid[req_bank];
wire        row_match      = bank_valid_now && (row_open[req_bank] == req_row);
wire        is_hit         = bank_valid_now &&  row_match;
wire        is_conflict    = bank_valid_now && !row_match;

// Latched access params (so we don't re-read addr/din after ce edge)
reg [8:0]  caddr_l;
reg [7:0]  wrdata_l;
reg        wr_l;
reg [1:0]  ba_l;
reg [12:0] row_l;

// ---------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------
always @(posedge clk) begin
	last_ce      <= ce;
	last_refresh <= refresh;

	sd_cmd  <= CMD_NOP;
	sd_data <= 16'bZ;

	// Default q increment when active
	if (q != ST_IDLE) q <= q + 4'd1;

	// -----------------------------------------------------------------
	// Power-on reset sequence (unchanged from baseline)
	// -----------------------------------------------------------------
	if (reset) begin
		sd_ba <= 0;
		if (q == 4'd0) begin
			if (reset == 13) begin
				sd_cmd  <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;   // A10=1, all banks
				q       <= 4'd1;                 // step through wait states
			end
			if (reset == 2) begin
				sd_cmd  <= CMD_LOAD_MODE;
				sd_addr <= MODE;
				q       <= 4'd1;
			end
		end
		// Roll q while waiting (matches baseline timing budget)
		if (q == 4'd9) q <= 4'd0;
		row_valid <= 4'b0000;
	end
	else begin
		// -------------------------------------------------------------
		// Sample data
		// -------------------------------------------------------------
		case (path)
		P_COLD:     if (q == 4'd6) begin dout_r <= sd_data; if (bt && !wr_l) dout_reu_r <= sd_data[15:8]; end
		P_HIT:      if (q == 4'd4) begin dout_r <= sd_data; if (bt && !wr_l) dout_reu_r <= sd_data[15:8]; end
		P_CONFLICT: if (q == 4'd8) begin dout_r <= sd_data; if (bt && !wr_l) dout_reu_r <= sd_data[15:8]; end
		default: ;
		endcase

		// -------------------------------------------------------------
		// Cold path commands
		// -------------------------------------------------------------
		if (path == P_COLD) begin
			if (q == 4'd1) begin
				sd_cmd <= CMD_ACTIVE;
				sd_ba  <= ba_l;
				sd_addr <= row_l;
			end
			if (q == 4'd3) begin
				if (wr_l) sd_data <= {wrdata_l, wrdata_l};
				sd_cmd  <= wr_l ? CMD_WRITE : CMD_READ;
				// auto-precharge BIT 10 = 0 -> keep row open
				sd_addr <= {~bt & wr_l, bt & wr_l, 2'b00, caddr_l};
			end
			if (q == 4'd7) q <= 4'd0;
		end

		// -------------------------------------------------------------
		// Hit path commands
		// -------------------------------------------------------------
		if (path == P_HIT) begin
			if (q == 4'd1) begin
				if (wr_l) sd_data <= {wrdata_l, wrdata_l};
				sd_cmd  <= wr_l ? CMD_WRITE : CMD_READ;
				sd_ba   <= ba_l;
				sd_addr <= {~bt & wr_l, bt & wr_l, 2'b00, caddr_l};
			end
			if (q == 4'd4) q <= 4'd0;
		end

		// -------------------------------------------------------------
		// Conflict path commands (precharge → activate → read)
		// -------------------------------------------------------------
		if (path == P_CONFLICT) begin
			if (q == 4'd1) begin
				sd_cmd  <= CMD_PRECHARGE;
				sd_ba   <= ba_l;
				sd_addr <= 13'b0000000000000;  // A10=0, single bank
				row_valid[ba_l] <= 1'b0;
			end
			if (q == 4'd3) begin
				sd_cmd  <= CMD_ACTIVE;
				sd_ba   <= ba_l;
				sd_addr <= row_l;
				row_open[ba_l]  <= row_l;
				row_valid[ba_l] <= 1'b1;
			end
			if (q == 4'd5) begin
				if (wr_l) sd_data <= {wrdata_l, wrdata_l};
				sd_cmd  <= wr_l ? CMD_WRITE : CMD_READ;
				sd_addr <= {~bt & wr_l, bt & wr_l, 2'b00, caddr_l};
			end
			if (q == 4'd9) q <= 4'd0;
		end

		// -------------------------------------------------------------
		// Refresh paths
		// -------------------------------------------------------------
		if (path == P_RFSH_PCH) begin
			if (q == 4'd1) begin
				sd_cmd  <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;   // A10=1 = all banks
				row_valid <= 4'b0000;
			end
			if (q == 4'd3) sd_cmd <= CMD_AUTO_REFRESH;
			if (q == 4'd9) q <= 4'd0;
		end
		if (path == P_RFSH) begin
			if (q == 4'd1) sd_cmd <= CMD_AUTO_REFRESH;
			if (q == 4'd7) q <= 4'd0;
		end

		// -------------------------------------------------------------
		// Dispatch new request when idle
		// -------------------------------------------------------------
		if (q == ST_IDLE) begin
			// refresh takes priority over ce when both edges arrive
			if (refresh && !last_refresh) begin
				path <= (|row_valid) ? P_RFSH_PCH : P_RFSH;
				q    <= 4'd1;
			end
			else if (ce && !last_ce) begin
				// Latch access params
				caddr_l  <= {addr[23], addr[7:0]};
				wrdata_l <= din;
				wr_l     <= we;
				bt       <= addr[24];
				ba_l     <= req_bank;
				row_l    <= req_row;

				// Update row tracker speculatively for ACTIVE/hit cases.
				// For conflict, row_open is updated inside the conflict
				// path at q=3 (after the precharge).
				if (is_hit) begin
					path <= P_HIT;
				end
				else if (is_conflict) begin
					path <= P_CONFLICT;
				end
				else begin
					path <= P_COLD;
					row_open[req_bank]  <= req_row;
					row_valid[req_bank] <= 1'b1;
				end
				q <= 4'd1;
			end
		end
	end
end

// ---------------------------------------------------------------------
// SDRAM clock output (DDIO, unchanged)
// ---------------------------------------------------------------------
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
