//
// sdram_pm.v — page-mode SDRAM controller (Build C)
//
// Build A wedged the C64 at PC=$0D62 — page-mode FSM was buggy.
// Build B (baseline-equivalent + ready output) boots cleanly.
// Build C re-adds page-mode but keeps baseline's command timing —
// ACTIVE fires on the ce-edge cycle (NOT on q=1 like Build A did),
// READ fires at STATE_CMD_CONT=2, data samples at STATE_READ=5.
//
// Three paths, all sharing the same 8-cycle envelope (q=0..7):
//
//   COLD (bank closed at dispatch — same as baseline):
//     ce-edge   : ACTIVE registered, latch params, row_open/valid update
//     q=2       : READ/WRITE registered (with AP=0, keeps row open)
//     q=5       : dout_r sampled
//     q=7       : idle (q→0 via baseline `if(q||reset)` increment + wrap)
//
//   HIT (bank open & row matches):
//     ce-edge   : READ/WRITE registered DIRECTLY (skip ACTIVE)
//     q=3       : dout_r sampled (data available 3 clk64 after READ register)
//     q=7       : idle
//
//   CONFLICT (bank open, different row):
//     ce-edge   : single-bank PRECHARGE registered, row_valid[ba] cleared
//     q=2       : ACTIVE registered with new row, row_open/valid updated
//     q=4       : READ/WRITE registered (with AP=0)
//     q=7       : dout_r sampled
//
// Refresh:
//   If any row valid: PRECHARGE_ALL registered on refresh edge, AUTO_REFRESH
//                     at q=2, row_valid <= 0000 cleared on refresh edge.
//   Else            : AUTO_REFRESH registered directly on refresh edge.
//
// Backward-compat with baseline ports; adds `output ready`.
// Module name `sdram_pm` so it can coexist with `sdram.v`.
//
// Based on Till Harbaum's sdram.v (GPLv3).

module sdram_pm (

	// interface to the MT48LC16M16 chip
	output reg [12:0]	sd_addr,
	inout  reg [15:0]	sd_data,
	output reg [ 1:0]	sd_ba,
	output 				sd_cs,
	output 				sd_we,
	output 				sd_ras,
	output 				sd_cas,
	output 				sd_clk,
	output 		[1:0]	sd_dqm,

	input 		 		init,
	input 		 		clk,

	input      [24:0] addr,
	input      [ 7:0] din,
	output     [ 7:0]	dout,
	output     [ 7:0]	dout_hi,
	output     [ 7:0]	dout_lo,
	output     [ 7:0]	dout_reu,

	input 		 		refresh,
	input 		 		ce,
	input 		 		we,
	output 				ready
);

localparam RASCAS_DELAY   = 3'd2;
localparam BURST_LENGTH   = 3'b000;
localparam ACCESS_TYPE    = 1'b0;
localparam CAS_LATENCY    = 3'd2;
localparam OP_MODE        = 2'b00;
localparam NO_WRITE_BURST = 1'b1;

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

// ---------------------------------------------------------------------
// Cycle state machine — baseline 3-bit q rolls 0→7
// ---------------------------------------------------------------------
localparam STATE_CMD_START = 3'd0;
localparam STATE_CMD_CONT  = STATE_CMD_START  + RASCAS_DELAY;       // 2
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 1'd1;   // 5
localparam STATE_LAST      = 3'd7;

reg [2:0] q /* synthesis noprune */;
reg last_ce, last_refresh;
always @(posedge clk) begin
	last_ce <= ce;
	last_refresh <= refresh;
	if(ce && !last_ce) q <= 3'd1;
	if(q || reset) q <= q + 3'd1;
end

assign ready = (q == 3'd0) && !reset;

// ---------------------------------------------------------------------
// Path selector (which sequence this access is in)
// ---------------------------------------------------------------------
localparam P_COLD     = 2'd0;
localparam P_HIT      = 2'd1;
localparam P_CONFLICT = 2'd2;
localparam P_RFSH_PCH = 2'd3;  // refresh-with-precharge: AUTO_REFRESH at q=2

reg [1:0] path;

// Per-bank open-row tracking
reg [12:0] row_open [0:3];
reg [3:0]  row_valid;

// Latched params (so q=2/q=4 commands have stable values)
reg [8:0]  caddr_l;
reg [7:0]  wrdata_l;
reg        wr_l;
reg [12:0] row_l;
reg [1:0]  ba_l;

// Combinational hit/conflict detect
wire [1:0]  req_bank = addr[22:21];
wire [12:0] req_row  = addr[20:8];
wire        bank_valid_now = row_valid[req_bank];
wire        row_match      = bank_valid_now && (row_open[req_bank] == req_row);
wire        is_hit         = bank_valid_now &&  row_match;
wire        is_conflict    = bank_valid_now && !row_match;

// ---------------------------------------------------------------------
// Startup/reset (unchanged from baseline)
// ---------------------------------------------------------------------
initial reset = 5'h1f;
reg [4:0] reset;
always @(posedge clk) begin
	if(init) reset <= 5'h1f;
	else if((q == STATE_LAST) && (reset != 0)) reset <= reset - 5'd1;
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
// Main FSM
// ---------------------------------------------------------------------
always @(posedge clk) begin
	sd_cmd  <= CMD_NOP;
	sd_data <= 16'bZ;

	// Sample data based on which path is in flight
	if (q == STATE_READ && path == P_COLD) begin
		dout_r <= sd_data;
		if (bt && !wr_l) dout_reu_r <= sd_data[15:8];
	end
	if (q == 3'd3 && path == P_HIT) begin
		dout_r <= sd_data;
		if (bt && !wr_l) dout_reu_r <= sd_data[15:8];
	end
	if (q == 3'd7 && path == P_CONFLICT) begin
		dout_r <= sd_data;
		if (bt && !wr_l) dout_reu_r <= sd_data[15:8];
	end

	if (reset) begin
		// Power-on reset sequence (identical to baseline)
		sd_ba <= 0;
		row_valid <= 4'b0000;
		if (q == STATE_CMD_START) begin
			if (reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;
			end
			if (reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end
		end
	end
	else begin
		// -----------------------------------------------------------------
		// REFRESH PRIORITY: refresh edge issues PRECHARGE_ALL (if any row
		// open) or AUTO_REFRESH directly. Refresh fires every ~1us during
		// EXT cycles so it cannot collide with ce edges in practice.
		// -----------------------------------------------------------------
		if (refresh && !last_refresh) begin
			if (|row_valid) begin
				sd_cmd  <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;  // A10=1, all banks
				row_valid <= 4'b0000;
				path <= P_RFSH_PCH;
			end else begin
				sd_cmd <= CMD_AUTO_REFRESH;
				// path doesn't matter — no later commands issued
			end
		end

		// REFRESH_PCH path: AUTO_REFRESH at q=2 (2 cycles after PRECHARGE)
		if (path == P_RFSH_PCH && q == STATE_CMD_CONT) begin
			sd_cmd <= CMD_AUTO_REFRESH;
		end

		// -----------------------------------------------------------------
		// CE edge: dispatch into COLD / HIT / CONFLICT path
		// -----------------------------------------------------------------
		if (ce && !last_ce) begin
			// Latch params (common to all paths)
			caddr_l  <= {addr[23], addr[7:0]};
			wrdata_l <= din;
			wr_l     <= we;
			bt       <= addr[24];
			ba_l     <= req_bank;
			row_l    <= req_row;
			sd_ba    <= req_bank;

			if (is_hit) begin
				// HIT: skip ACTIVE — issue READ/WRITE on this cycle
				path <= P_HIT;
				if (we) sd_data <= {din, din};
				sd_cmd  <= we ? CMD_WRITE : CMD_READ;
				sd_addr <= {~addr[24] & we, addr[24] & we, 2'b00, addr[23], addr[7:0]};
			end
			else if (is_conflict) begin
				// CONFLICT: PRECHARGE this bank — ACTIVE at q=2, READ at q=4
				path <= P_CONFLICT;
				sd_cmd  <= CMD_PRECHARGE;
				sd_addr <= 13'b0000000000000;  // A10=0, single bank
				row_valid[req_bank] <= 1'b0;
			end
			else begin
				// COLD: standard ACTIVE — READ at q=2 (baseline timing)
				path <= P_COLD;
				sd_cmd  <= CMD_ACTIVE;
				sd_addr <= req_row;
				row_open[req_bank]  <= req_row;
				row_valid[req_bank] <= 1'b1;
			end
		end

		// COLD path: READ/WRITE at q=2 (baseline STATE_CMD_CONT)
		if (path == P_COLD && q == STATE_CMD_CONT) begin
			if (wr_l) sd_data <= {wrdata_l, wrdata_l};
			sd_cmd  <= wr_l ? CMD_WRITE : CMD_READ;
			// AP=0 → keep row open for subsequent hits
			sd_addr <= {~bt & wr_l, bt & wr_l, 2'b00, caddr_l};
		end

		// CONFLICT path: ACTIVE at q=2, READ at q=4
		if (path == P_CONFLICT && q == STATE_CMD_CONT) begin
			sd_cmd  <= CMD_ACTIVE;
			sd_addr <= row_l;
			row_open[ba_l]  <= row_l;
			row_valid[ba_l] <= 1'b1;
		end
		if (path == P_CONFLICT && q == 3'd4) begin
			if (wr_l) sd_data <= {wrdata_l, wrdata_l};
			sd_cmd  <= wr_l ? CMD_WRITE : CMD_READ;
			sd_addr <= {~bt & wr_l, bt & wr_l, 2'b00, caddr_l};
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
