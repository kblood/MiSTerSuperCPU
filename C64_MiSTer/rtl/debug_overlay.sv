// debug_overlay.sv - On-screen hex debug overlay for MiSTer C64 SuperCPU
//
// Renders CPU debug state as hex text in the top border area of the
// VIC-II video output. Self-contained with embedded 4x6 hex font.
//
// Display layout (rendered in top border, 2 rows):
//   Row 1: A:xxxx D:xx W:x B:xx
//   Row 2: S:xxxx P:xx I:xx E:x
//
// All position tracking uses registered counters (no division/modulo).

module debug_overlay (
	input         clk,        // system clock (32 MHz)
	input         enable,     // overlay enable
	input         hblank,     // horizontal blank from video_sync
	input         vblank,     // vertical blank from video_sync

	// Debug data inputs (active CPU's signals)
	input  [15:0] cpu_addr,
	input   [7:0] cpu_data,
	input         cpu_we,
	input         cpu_en,     // CPU enable pulse active
	input         emu_mode,   // emulation mode
	input   [7:0] bank_addr,  // bank byte (A16-A23)
	input         supercpu,   // SuperCPU enabled
	input  [15:0] cpu_sp,     // stack pointer
	input   [7:0] cpu_p,      // processor status register
	input   [7:0] cpu_ir,     // instruction register (current opcode)

	// Video overlay output
	output reg    overlay_active,
	output reg [7:0] overlay_r,
	output reg [7:0] overlay_g,
	output reg [7:0] overlay_b
);

// -----------------------------------------------------------------------
// Raster position tracking (registered counters, no division)
// -----------------------------------------------------------------------

reg [1:0] clk_div;
reg [9:0] dot_cnt;
reg [8:0] line_cnt;
reg       hblank_r, vblank_r;
reg       dot_tick;  // pulses once per pixel (every 4 clk32)

always @(posedge clk) begin
	hblank_r <= hblank;
	vblank_r <= vblank;
	dot_tick <= 0;

	if (hblank_r && !hblank) begin
		dot_cnt <= 0;
		clk_div <= 0;
	end else begin
		clk_div <= clk_div + 1'b1;
		if (clk_div == 2'd3) begin
			dot_cnt  <= dot_cnt + 1'b1;
			dot_tick <= 1;
		end
	end

	if (vblank_r && !vblank)
		line_cnt <= 0;
	else if (hblank_r && !hblank)
		line_cnt <= line_cnt + 1'b1;
end

// -----------------------------------------------------------------------
// Latch debug data once per frame (at vblank) for stable display
// -----------------------------------------------------------------------

reg [15:0] lat_addr;
reg  [7:0] lat_data;
reg        lat_we;
reg        lat_emu;
reg  [7:0] lat_bank;
reg [15:0] lat_sp;
reg  [7:0] lat_p;
reg  [7:0] lat_ir;

always @(posedge clk) begin
	if (vblank_r && !vblank) begin
		lat_addr <= cpu_addr;
		lat_data <= cpu_data;
		lat_we   <= cpu_we;
		lat_emu  <= emu_mode;
		lat_bank <= bank_addr;
		lat_sp   <= cpu_sp;
		lat_p    <= cpu_p;
		lat_ir   <= cpu_ir;
	end
end

// -----------------------------------------------------------------------
// Character position counters
// -----------------------------------------------------------------------

localparam OVERLAY_X_START = 10'd4;
localparam OVERLAY_Y_START = 9'd2;
localparam OVERLAY_Y_END   = 9'd16; // 2 rows x 6px + 2px gap = 14 lines, end at 16
localparam NUM_CHARS       = 5'd22;  // max chars per row
localparam ROW1_Y_END      = 9'd8;   // row 1: lines 2-7 (6px)
localparam ROW2_Y_START    = 9'd9;   // row 2: lines 9-14 (1px gap)

reg [4:0] char_idx;    // which character position (0-21)
reg [2:0] px_in_char;  // pixel within character (0-4: 0-3=glyph, 4=gap)
reg       in_overlay_x; // within overlay X range
reg       in_overlay_y; // within overlay Y range

always @(posedge clk) begin
	if (hblank_r && !hblank) begin
		// Start of line: reset horizontal overlay state
		char_idx    <= 0;
		px_in_char  <= 0;
		in_overlay_x <= 0;
	end else if (dot_tick) begin
		if (dot_cnt == OVERLAY_X_START) begin
			in_overlay_x <= 1;
			char_idx     <= 0;
			px_in_char   <= 0;
		end else if (in_overlay_x) begin
			if (px_in_char == 3'd4) begin
				px_in_char <= 0;
				if (char_idx == NUM_CHARS - 1'b1)
					in_overlay_x <= 0;
				else
					char_idx <= char_idx + 1'b1;
			end else begin
				px_in_char <= px_in_char + 1'b1;
			end
		end
	end

	// Y range check (registered)
	if (vblank_r && !vblank)
		in_overlay_y <= 0;
	else if (hblank_r && !hblank) begin
		if (line_cnt == OVERLAY_Y_START)
			in_overlay_y <= 1;
		else if (line_cnt == OVERLAY_Y_END)
			in_overlay_y <= 0;
	end
end

// Row selection: row 0 for lines 2-7, row 1 for lines 9-14
wire       char_row = (line_cnt >= ROW2_Y_START);
// Gap line between rows (line 8): no text
wire       in_gap = (line_cnt == ROW1_Y_END);
// Font row within current character row (0-5)
wire [2:0] font_row = char_row ? (line_cnt[2:0] - ROW2_Y_START[2:0])
                                : (line_cnt[2:0] - OVERLAY_Y_START[2:0]);

// -----------------------------------------------------------------------
// 4x6 hex font ROM
// Each character: 4 pixels wide, 6 rows tall
// Encoded as 6 nibbles (24 bits), MSB of each nibble = leftmost pixel
// -----------------------------------------------------------------------

reg [23:0] font_data;

always @(*) begin
	case (char_code)
		5'h0:    font_data = 24'h699996; // 0
		5'h1:    font_data = 24'h262227; // 1
		5'h2:    font_data = 24'h69168F; // 2
		5'h3:    font_data = 24'h692196; // 3
		5'h4:    font_data = 24'h99F111; // 4
		5'h5:    font_data = 24'hF8E11E; // 5
		5'h6:    font_data = 24'h68E996; // 6
		5'h7:    font_data = 24'hF12444; // 7
		5'h8:    font_data = 24'h696996; // 8
		5'h9:    font_data = 24'h697116; // 9
		5'hA:    font_data = 24'h69F999; // A
		5'hB:    font_data = 24'hE9E99E; // B
		5'hC:    font_data = 24'h698896; // C
		5'hD:    font_data = 24'hE999E0; // D
		5'hE:    font_data = 24'hF8E88F; // E
		5'hF:    font_data = 24'hF8E888; // F
		5'h10:   font_data = 24'h68E99E; // S (code 16)
		5'h11:   font_data = 24'hE9E888; // P (code 17)
		5'h12:   font_data = 24'hE444E0; // I (code 18)
		5'h14:   font_data = 24'h999BF6; // W (code 20)
		5'h15:   font_data = 24'h066060; // : (code 21)
		5'h16:   font_data = 24'h000000; // space (code 22)
		default: font_data = 24'h000000;
	endcase
end

// -----------------------------------------------------------------------
// Character string mapping (combinational, uses latched data)
// Row 1: "A:xxxx D:xx W:x B:xx"  (22 chars)
// Row 2: "S:xxxx P:xx I:xx E:x"  (22 chars)
// -----------------------------------------------------------------------

reg [4:0] char_code;

always @(*) begin
	if (!char_row) begin
		// Row 1: A:xxxx D:xx W:x B:xx
		case (char_idx)
			5'd0:  char_code = 5'hA;                   // 'A'
			5'd1:  char_code = 5'h15;                   // ':'
			5'd2:  char_code = {1'b0, lat_addr[15:12]};
			5'd3:  char_code = {1'b0, lat_addr[11:8]};
			5'd4:  char_code = {1'b0, lat_addr[7:4]};
			5'd5:  char_code = {1'b0, lat_addr[3:0]};
			5'd6:  char_code = 5'h16;                   // ' '
			5'd7:  char_code = 5'hD;                    // 'D'
			5'd8:  char_code = 5'h15;                   // ':'
			5'd9:  char_code = {1'b0, lat_data[7:4]};
			5'd10: char_code = {1'b0, lat_data[3:0]};
			5'd11: char_code = 5'h16;                   // ' '
			5'd12: char_code = 5'h14;                   // 'W'
			5'd13: char_code = 5'h15;                   // ':'
			5'd14: char_code = {4'b0, lat_we};
			5'd15: char_code = 5'h16;                   // ' '
			5'd16: char_code = 5'hB;                    // 'B'
			5'd17: char_code = 5'h15;                   // ':'
			5'd18: char_code = {1'b0, lat_bank[7:4]};
			5'd19: char_code = {1'b0, lat_bank[3:0]};
			5'd20: char_code = 5'h16;                   // ' '
			5'd21: char_code = 5'h16;                   // ' '
			default: char_code = 5'h16;
		endcase
	end else begin
		// Row 2: S:xxxx P:xx I:xx E:x
		case (char_idx)
			5'd0:  char_code = 5'h10;                   // 'S'
			5'd1:  char_code = 5'h15;                   // ':'
			5'd2:  char_code = {1'b0, lat_sp[15:12]};
			5'd3:  char_code = {1'b0, lat_sp[11:8]};
			5'd4:  char_code = {1'b0, lat_sp[7:4]};
			5'd5:  char_code = {1'b0, lat_sp[3:0]};
			5'd6:  char_code = 5'h16;                   // ' '
			5'd7:  char_code = 5'h11;                   // 'P'
			5'd8:  char_code = 5'h15;                   // ':'
			5'd9:  char_code = {1'b0, lat_p[7:4]};
			5'd10: char_code = {1'b0, lat_p[3:0]};
			5'd11: char_code = 5'h16;                   // ' '
			5'd12: char_code = 5'h12;                   // 'I'
			5'd13: char_code = 5'h15;                   // ':'
			5'd14: char_code = {1'b0, lat_ir[7:4]};
			5'd15: char_code = {1'b0, lat_ir[3:0]};
			5'd16: char_code = 5'h16;                   // ' '
			5'd17: char_code = 5'hE;                    // 'E'
			5'd18: char_code = 5'h15;                   // ':'
			5'd19: char_code = {4'b0, lat_emu};
			5'd20: char_code = 5'h16;                   // ' '
			5'd21: char_code = 5'h16;                   // ' '
			default: char_code = 5'h16;
		endcase
	end
end

// -----------------------------------------------------------------------
// Pixel extraction (registered output for clean timing)
// -----------------------------------------------------------------------

// Extract the correct row from font_data, then the correct pixel
wire [3:0] row_bits = font_data[23 - {font_row, 2'b00} -: 4];
wire       pixel_on = (px_in_char < 3'd4) && row_bits[3 - px_in_char[1:0]] && !in_gap;

wire       in_region = enable && in_overlay_x && in_overlay_y && !hblank && !vblank;

// Registered outputs to prevent glitches
always @(posedge clk) begin
	overlay_active <= in_region;
	if (in_region && pixel_on) begin
		overlay_r <= 8'h00;
		overlay_g <= 8'hFF;
		overlay_b <= 8'h00;
	end else if (in_region) begin
		// Dark background behind text for readability
		overlay_r <= 8'h00;
		overlay_g <= 8'h18;
		overlay_b <= 8'h00;
	end else begin
		overlay_r <= 8'h00;
		overlay_g <= 8'h00;
		overlay_b <= 8'h00;
	end
end

endmodule
