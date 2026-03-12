// debug_overlay.sv - On-screen hex debug overlay for MiSTer C64 SuperCPU
//
// Renders CPU debug state as hex text in the top border area of the
// VIC-II video output. Self-contained with embedded 4x6 hex font.
//
// Display layout (rendered in top border, 4 rows):
//   Row 1: A:xxxx B:xx K:xx R:xx   (B=current bank, K=max bank seen, R=addr at max bank)
//   Row 2: S:xxxx P:xx I:xx E:x
//   Row 3: W:xxxx D:xx P:xxxx oo   (rolling write) or C:vvvv HA D:DD S:SSSS (c-access $00 hit)
//   Row 4: T:x C:xxxx E:xxxx N:xx  (turbo_en, cache hits/frame, enables/frame, frame#)
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
	input   [7:0] cia1_pa,    // CIA1 Port A (sticky max bank)
	input   [7:0] cia1_pb,    // CIA1 Port B (addr when max bank entered)
	// Screen-RAM write detector (last write to $0400-$07FF)
	input  [15:0] scr_wr_addr,
	input  [15:0] scr_wr_pc,
	input   [7:0] scr_wr_data,
	input   [7:0] scr_wr_ir,
	input         scr_zero_hit, // sticky flag: '1' when a $00 write was captured
	input   [7:0] scr_wr_bank,  // bank of last captured screen write
	input         scr_arm,      // write-capture arm state
	// VIC read-side capture
	input         vic_zero_hit,  // sticky flag: '1' when VIC read $00 from screen RAM
	input  [15:0] vic_zero_addr, // VIC address where $00 was read
	input  [15:0] vic_zero_cpu,  // CPU address at that moment
	input  [15:0] vic_zero_sysaddr, // full systemAddr latched at CPUC
	input         vic_wr_match,  // '1' if last CPU screen write matched vic_zero_addr
	input  [15:0] vic_wr_pc,     // PC of matching last CPU write
	input   [7:0] vic_prearm_cnt, // VIC $00 hits before write capture armed
	input   [7:0] vic_hit_cnt,    // VIC $00 hits after write capture armed
	input   [7:0] vic_mode,       // runtime test mode (D07B bits[1:0])
	input   [7:0] vic_cpuf_zero_cnt,      // CPUF live vicDi == $00
	input   [7:0] vic_cpue_live_zero_cnt, // CPUE live vicDi == $00
	input   [7:0] vic_cpue_hold_zero_cnt, // CPUE held data == $00
	input   [7:0] vic_cpue_mismatch_cnt,  // CPUE live data != held data

	// Turbo/cache diagnostics (active signals, counted per frame)
	input         turbo_en,
	input         cache_hit_pulse,
	input         enable_cpu_pulse,

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

reg [15:0] ovl_frame_cnt;  // frame counter for freeze detection

reg [15:0] lat_addr;
reg  [7:0] lat_data;
reg        lat_we;
reg        lat_emu;
reg  [7:0] lat_bank;
reg [15:0] lat_sp;
reg  [7:0] lat_p;
reg  [7:0] lat_ir;
reg  [7:0] lat_cia1_pa;
reg  [7:0] lat_cia1_pb;
reg [15:0] lat_scr_wr_addr;
reg [15:0] lat_scr_wr_pc;
reg  [7:0] lat_scr_wr_data;
reg  [7:0] lat_scr_wr_ir;
reg        lat_scr_zero_hit;
reg  [7:0] lat_scr_wr_bank;
reg        lat_scr_arm;
reg        lat_vic_zero_hit;
reg [15:0] lat_vic_zero_addr;
reg [15:0] lat_vic_zero_cpu;
reg [15:0] lat_vic_zero_sysaddr;
reg        lat_vic_wr_match;
reg [15:0] lat_vic_wr_pc;
reg  [7:0] lat_vic_prearm_cnt;
reg  [7:0] lat_vic_hit_cnt;
reg  [7:0] lat_vic_mode;
reg  [7:0] lat_vic_cpuf_zero_cnt;
reg  [7:0] lat_vic_cpue_live_zero_cnt;
reg  [7:0] lat_vic_cpue_hold_zero_cnt;
reg  [7:0] lat_vic_cpue_mismatch_cnt;
reg  [7:0] lat_frame_lo;  // low byte of frame counter
// Turbo/cache per-frame counters (20-bit to avoid overflow at high enable rates)
// Displayed value = count / 16 (to fit in 16-bit overlay fields).
// To get real count: multiply displayed value by 16.
reg [19:0] ch_cnt;       // cache/BRAM hit pulse counter (running)
reg [19:0] en_cnt;       // enableCpu pulse counter (running)
reg [15:0] lat_ch_cnt;   // latched at vblank (count / 16)
reg [15:0] lat_en_cnt;   // latched at vblank (count / 16)
reg        lat_turbo_en; // latched at vblank

// Per-frame counter logic: count pulses between vblanks
always @(posedge clk) begin
	if (cache_hit_pulse)
		ch_cnt <= ch_cnt + 1'b1;
	if (enable_cpu_pulse)
		en_cnt <= en_cnt + 1'b1;
	if (vblank_r && !vblank) begin
		ch_cnt <= 0;
		en_cnt <= 0;
	end
end

always @(posedge clk) begin
	if (vblank_r && !vblank) begin
		ovl_frame_cnt   <= ovl_frame_cnt + 1'b1;
		lat_frame_lo    <= ovl_frame_cnt[7:0];
		lat_turbo_en    <= turbo_en;
		lat_ch_cnt      <= ch_cnt[19:4];  // displayed = count/16
		lat_en_cnt      <= en_cnt[19:4];  // displayed = count/16
		lat_addr        <= cpu_addr;
		lat_data        <= cpu_data;
		lat_we          <= cpu_we;
		lat_emu         <= emu_mode;
		lat_bank        <= bank_addr;
		lat_sp          <= cpu_sp;
		lat_p           <= cpu_p;
		lat_ir          <= cpu_ir;
		lat_cia1_pa     <= cia1_pa;
		lat_cia1_pb     <= cia1_pb;
		lat_scr_wr_addr <= scr_wr_addr;
		lat_scr_wr_pc   <= scr_wr_pc;
		lat_scr_wr_data <= scr_wr_data;
		lat_scr_wr_ir   <= scr_wr_ir;
		lat_scr_zero_hit <= scr_zero_hit;
		lat_scr_wr_bank <= scr_wr_bank;
		lat_scr_arm <= scr_arm;
		lat_vic_zero_hit  <= vic_zero_hit;
		lat_vic_zero_addr <= vic_zero_addr;
		lat_vic_zero_cpu  <= vic_zero_cpu;
		lat_vic_zero_sysaddr <= vic_zero_sysaddr;
		lat_vic_wr_match <= vic_wr_match;
		lat_vic_wr_pc <= vic_wr_pc;
		lat_vic_prearm_cnt <= vic_prearm_cnt;
		lat_vic_hit_cnt <= vic_hit_cnt;
		lat_vic_mode <= vic_mode;
		lat_vic_cpuf_zero_cnt <= vic_cpuf_zero_cnt;
		lat_vic_cpue_live_zero_cnt <= vic_cpue_live_zero_cnt;
		lat_vic_cpue_hold_zero_cnt <= vic_cpue_hold_zero_cnt;
		lat_vic_cpue_mismatch_cnt <= vic_cpue_mismatch_cnt;
	end
end

// -----------------------------------------------------------------------
// Character position counters
// -----------------------------------------------------------------------

// Overlay placed in top border area. Constants chosen so 4x6px rows + 3 gap lines
// = 27 lines fit in the top border.
// NOTE: in_overlay_y is registered (1 line late), so we trigger at Y_START-1.
localparam OVERLAY_X_START = 10'd4;
localparam OVERLAY_Y_START = 9'd6;    // first line of row 1 (border area, with monitor margin)
localparam ROW1_Y_END      = 9'd12;   // gap line between row 1 and row 2
localparam ROW2_Y_START    = 9'd13;   // first line of row 2
localparam ROW2_Y_END      = 9'd19;   // gap line between row 2 and row 3
localparam ROW3_Y_START    = 9'd20;   // first line of row 3
localparam ROW3_Y_END      = 9'd26;   // gap line between row 3 and row 4
localparam ROW4_Y_START    = 9'd27;   // first line of row 4
localparam OVERLAY_Y_END   = 9'd33;   // last line + 1 (exclusive)
localparam NUM_CHARS       = 5'd22;   // max chars per row

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

	// Y range check (registered, so trigger one line EARLY to compensate)
	if (vblank_r && !vblank)
		in_overlay_y <= 0;
	else if (hblank_r && !hblank) begin
		if (line_cnt == OVERLAY_Y_START - 1)   // fire early: active on OVERLAY_Y_START
			in_overlay_y <= 1;
		else if (line_cnt == OVERLAY_Y_END - 1) // fire early: inactive on OVERLAY_Y_END
			in_overlay_y <= 0;
	end
end

// Row selection: 0=row1, 1=row2, 2=row3, 3=row4
wire [1:0] char_row = (line_cnt >= ROW4_Y_START) ? 2'd3 :
                      (line_cnt >= ROW3_Y_START) ? 2'd2 :
                      (line_cnt >= ROW2_Y_START)  ? 2'd1 : 2'd0;
// Gap lines between rows: no text rendered
wire       in_gap = (line_cnt == ROW1_Y_END) || (line_cnt == ROW2_Y_END) || (line_cnt == ROW3_Y_END);
// Font row within current character row (0-5)
wire [2:0] font_row = (char_row == 2'd3) ? (line_cnt[2:0] - ROW4_Y_START[2:0]) :
                      (char_row == 2'd2) ? (line_cnt[2:0] - ROW3_Y_START[2:0]) :
                      (char_row == 2'd1) ? (line_cnt[2:0] - ROW2_Y_START[2:0]) :
                                           (line_cnt[2:0] - OVERLAY_Y_START[2:0]);

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
		5'h13:   font_data = 24'h9ACCA9; // K (code 19)
		5'h14:   font_data = 24'h99BFD9; // W (code 20) - zigzag bottom half
		5'h15:   font_data = 24'h066060; // : (code 21)
		5'h16:   font_data = 24'h000000; // space (code 22)
		5'h17:   font_data = 24'hE9ECA9; // R (code 23)
		5'h18:   font_data = 24'h699996; // O (code 24) - oval like 0
		5'h19:   font_data = 24'h9F9999; // M (code 25)
		5'h1A:   font_data = 24'hF66666; // T (code 26)
		5'h1B:   font_data = 24'h9DB999; // N (code 27)
		default: font_data = 24'h000000;
	endcase
end

// -----------------------------------------------------------------------
// Character string mapping (combinational, uses latched data)
// Row 1: "A:xxxx B:xx K:xx R:xx"  (22 chars)
// Row 2: "S:xxxx P:xx I:xx E:x"   (22 chars)
// Row 3: "W:xxxx D:xx P:xxxx oo " (22 chars, W=write addr, D=data, P=PC, oo=opcode)
// -----------------------------------------------------------------------

reg [4:0] char_code;

always @(*) begin
	case (char_row)
	2'd0: begin
		// Row 1: A:xxxx B:xx K:xx R:xx
		case (char_idx)
			5'd0:  char_code = 5'hA;                   // 'A'
			5'd1:  char_code = 5'h15;                   // ':'
			5'd2:  char_code = {1'b0, lat_addr[15:12]};
			5'd3:  char_code = {1'b0, lat_addr[11:8]};
			5'd4:  char_code = {1'b0, lat_addr[7:4]};
			5'd5:  char_code = {1'b0, lat_addr[3:0]};
			5'd6:  char_code = 5'h16;                   // ' '
			5'd7:  char_code = 5'hB;                    // 'B' (current bank byte)
			5'd8:  char_code = 5'h15;                   // ':'
			5'd9:  char_code = {1'b0, lat_bank[7:4]};
			5'd10: char_code = {1'b0, lat_bank[3:0]};
			5'd11: char_code = 5'h16;                   // ' '
			5'd12: char_code = 5'h13;                   // 'K' (sticky max bank)
			5'd13: char_code = 5'h15;                   // ':'
			5'd14: char_code = {1'b0, lat_cia1_pa[7:4]};
			5'd15: char_code = {1'b0, lat_cia1_pa[3:0]};
			5'd16: char_code = 5'h16;                   // ' '
			5'd17: char_code = 5'h17;                   // 'R' (addr at max bank)
			5'd18: char_code = 5'h15;                   // ':'
			5'd19: char_code = {1'b0, lat_cia1_pb[7:4]};
			5'd20: char_code = {1'b0, lat_cia1_pb[3:0]};
			5'd21: char_code = 5'h16;
			default: char_code = 5'h16;
		endcase
	end
	2'd1: begin
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
			5'd20: char_code = 5'h16;
			5'd21: char_code = 5'h16;
			default: char_code = 5'h16;
		endcase
	end
	2'd2: begin
		// Row 3 - three priority levels:
		//   VIC hit:   C:vvvv M:x D:DD P:PPPP (M=last CPU write addr match to VIC-hit addr)
		//   Write hit: 0:xxxx D:00 P:xxxx   (write-side $00 frozen)
		//   Rolling:   W:xxxx D:xx P:xxxx oo (normal rolling capture)
		if (lat_vic_zero_hit) begin
			// Badline c-access $00 detected at VIC2.
			// Format: C:vvvv M:x D:DD P:PPPP
			//   vvvv = vicAddr at CPUC (c-access address, VM & colCounter)
			//   x    = 1 if last captured CPU screen write address matched vvvv
			//   DD   = vicDi[5:0] at VIC2 (from dbg_vic_zero_cpu[13:8])
			//   PPPP = PC from that matching write (0 if no match)
			case (char_idx)
				5'd0:  char_code = 5'hC;                             // 'C'
				5'd1:  char_code = 5'h15;                            // ':'
				5'd2:  char_code = {1'b0, lat_vic_zero_addr[15:12]};
				5'd3:  char_code = {1'b0, lat_vic_zero_addr[11:8]};
				5'd4:  char_code = {1'b0, lat_vic_zero_addr[7:4]};
				5'd5:  char_code = {1'b0, lat_vic_zero_addr[3:0]};
				5'd6:  char_code = 5'h16;                            // ' '
				5'd7:  char_code = 5'h19;                            // 'M'
				5'd8:  char_code = 5'h15;                            // ':'
				5'd9:  char_code = {4'b0, lat_vic_wr_match};
				5'd10: char_code = 5'h16;                            // ' '
				5'd11: char_code = 5'hD;                             // 'D'
				5'd12: char_code = 5'h15;                            // ':'
				5'd13: char_code = {1'b0, 2'b0, lat_vic_zero_cpu[13:12]}; // vicDi[5:4]@VIC2
				5'd14: char_code = {1'b0, lat_vic_zero_cpu[11:8]};   // vicDi[3:0]@VIC2
				5'd15: char_code = 5'h16;                            // ' '
				5'd16: char_code = 5'h11;                            // 'P'
				5'd17: char_code = 5'h15;                            // ':'
				5'd18: char_code = {1'b0, lat_vic_wr_pc[15:12]};
				5'd19: char_code = {1'b0, lat_vic_wr_pc[11:8]};
				5'd20: char_code = {1'b0, lat_vic_wr_pc[7:4]};
				5'd21: char_code = {1'b0, lat_vic_wr_pc[3:0]};
				default: char_code = 5'h16;
			endcase
		end
		else begin
			// Write-side or rolling capture
			case (char_idx)
				5'd0:  char_code = lat_scr_zero_hit ? 5'h0 : 5'h14; // '0' if frozen, 'W' if rolling
				5'd1:  char_code = 5'h15;                         // ':'
				5'd2:  char_code = {1'b0, lat_scr_wr_addr[15:12]};
				5'd3:  char_code = {1'b0, lat_scr_wr_addr[11:8]};
				5'd4:  char_code = {1'b0, lat_scr_wr_addr[7:4]};
				5'd5:  char_code = {1'b0, lat_scr_wr_addr[3:0]};
				5'd6:  char_code = 5'h16;                         // ' '
				5'd7:  char_code = 5'hD;                          // 'D'
				5'd8:  char_code = 5'h15;                         // ':'
				5'd9:  char_code = {1'b0, lat_scr_wr_data[7:4]};
				5'd10: char_code = {1'b0, lat_scr_wr_data[3:0]};
				5'd11: char_code = 5'h16;                         // ' '
				5'd12: char_code = 5'h11;                         // 'P' (PC at write)
				5'd13: char_code = 5'h15;                         // ':'
				5'd14: char_code = {1'b0, lat_scr_wr_pc[15:12]};
				5'd15: char_code = {1'b0, lat_scr_wr_pc[11:8]};
				5'd16: char_code = {1'b0, lat_scr_wr_pc[7:4]};
				5'd17: char_code = {1'b0, lat_scr_wr_pc[3:0]};
				5'd18: char_code = 5'h16;                         // ' '
				5'd19: char_code = {1'b0, lat_scr_wr_ir[7:4]};
				5'd20: char_code = {1'b0, lat_scr_wr_ir[3:0]};
				5'd21: char_code = 5'h16;
				default: char_code = 5'h16;
			endcase
		end
	end
	default: begin
		// Row 4: T:x C:xxxx E:xxxx N:xx
		//   T = turbo_en (0/1)
		//   C = (cache OR bram) hit count / 16 per frame
		//   E = enableCpu count / 16 per frame (multiply by 16 for real count)
		//   N = frame counter (8-bit, for freeze detection)
		case (char_idx)
			5'd0:  char_code = 5'h1A;                  // 'T'
			5'd1:  char_code = 5'h15;                  // ':'
			5'd2:  char_code = {4'b0, lat_turbo_en};
			5'd3:  char_code = 5'h16;                  // ' '
			5'd4:  char_code = 5'hC;                   // 'C'
			5'd5:  char_code = 5'h15;                  // ':'
			5'd6:  char_code = {1'b0, lat_ch_cnt[15:12]};
			5'd7:  char_code = {1'b0, lat_ch_cnt[11:8]};
			5'd8:  char_code = {1'b0, lat_ch_cnt[7:4]};
			5'd9:  char_code = {1'b0, lat_ch_cnt[3:0]};
			5'd10: char_code = 5'h16;                  // ' '
			5'd11: char_code = 5'hE;                   // 'E'
			5'd12: char_code = 5'h15;                  // ':'
			5'd13: char_code = {1'b0, lat_en_cnt[15:12]};
			5'd14: char_code = {1'b0, lat_en_cnt[11:8]};
			5'd15: char_code = {1'b0, lat_en_cnt[7:4]};
			5'd16: char_code = {1'b0, lat_en_cnt[3:0]};
			5'd17: char_code = 5'h16;                  // ' '
			5'd18: char_code = 5'h1B;                  // 'N'
			5'd19: char_code = {1'b0, lat_frame_lo[7:4]};
			5'd20: char_code = {1'b0, lat_frame_lo[3:0]};
			5'd21: char_code = 5'h16;
			default: char_code = 5'h16;
		endcase
	end
	endcase
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
		// Bright white text for maximum AI/OCR readability
		overlay_r <= 8'hFF;
		overlay_g <= 8'hFF;
		overlay_b <= 8'hFF;
	end else if (in_region) begin
		// Solid black background for maximum contrast
		overlay_r <= 8'h00;
		overlay_g <= 8'h00;
		overlay_b <= 8'h00;
	end else begin
		overlay_r <= 8'h00;
		overlay_g <= 8'h00;
		overlay_b <= 8'h00;
	end
end

endmodule
