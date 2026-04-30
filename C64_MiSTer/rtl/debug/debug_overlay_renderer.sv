// debug_overlay_renderer.sv
//
// Pixel-rate overlay renderer. Walks a 22-col x 4-row grid of 5x6 char
// cells (4-px-wide glyph + 1-px right gap) at the top of the frame.
// Each cell pulls a 6-bit glyph id from debug_overlay_format and looks
// up the row pixels via debug_font_4x6.
//
// Geometry:
//   X 4..114 inclusive-low / exclusive-high  -> 110 px wide -> 22 cells * 5 px
//   Y 6..30  inclusive-low / exclusive-high  -> 24 px tall  -> 4 cells * 6 px
//
// The pool/pool-binding is gated by DBG_OVERLAY in c64.sv (the parent
// only instantiates this module when DBG_OVERLAY is set), so we don't
// need a `\`ifdef inside the module body.

`include "debug_pkg.svh"

module debug_overlay_renderer #(
	parameter int X_LO = 4,
	parameter int X_HI = 114,   // exclusive (110 px = 22 * 5)
	// Y_LO/Y_HI count active-video scanlines (v_cnt resets when vblank
	// falls = start of visible area). Y_LO=6 puts the box in the C64
	// top border, matching master's known-good geometry. 2026-04-30:
	// extended to 5 rows (30 px) for layout-1 DD00-write-PC capture.
	parameter int Y_LO = 6,
	parameter int Y_HI = 78     // exclusive (72 px = 12 * 6) — row 11 = op_count
) (
	input  logic       clk_pix,    // CLK_VIDEO (= clk64)
	input  logic       ce_pix,     // pixel enable

	input  logic       hblank,     // C64 internal hblank (clk32 domain)
	input  logic       vblank,     // C64 internal vblank (clk32 domain)

	input  logic       visible,    // runtime show/hide (status[83])

`ifdef DBG_OVERLAY
	input  dbg_pool_t  pool,
`endif

	input  logic [7:0] r_in,
	input  logic [7:0] g_in,
	input  logic [7:0] b_in,

	output logic [7:0] r_out,
	output logic [7:0] g_out,
	output logic [7:0] b_out
);

	// ---- Sync edge detection ------------------------------------------
	logic hb_d, vb_d;
	logic hb_fall, vb_fall;

	always_ff @(posedge clk_pix) begin
		hb_d <= hblank;
		vb_d <= vblank;
	end

	assign hb_fall = ~hblank & hb_d;     // hblank 1 -> 0 = active pixels start
	assign vb_fall = ~vblank & vb_d;     // vblank 1 -> 0 = active video starts

	// ---- H/V counters -------------------------------------------------
	// h_cnt = horizontal pixel within active video (resets when hblank falls).
	// v_cnt = vertical scanline within active video (resets when vblank falls
	// and ticks each hblank_fall, i.e. each new active scanline).
	logic [10:0] h_cnt;
	logic [9:0]  v_cnt;

	always_ff @(posedge clk_pix) begin
		if (vb_fall) begin
			h_cnt <= '0;
			v_cnt <= '0;
		end
		else if (hb_fall) begin
			h_cnt <= '0;
			v_cnt <= v_cnt + 10'd1;
		end
		else if (ce_pix) begin
			h_cnt <= h_cnt + 11'd1;
		end
	end

	// ---- Cell stepping ------------------------------------------------
	// pix_x / pix_y are the sub-cell offsets; cell_x / cell_y identify
	// which character cell we're inside. They're advanced with the
	// pixel/scanline ticks and clamped to '0 outside the box.
	logic [4:0] cell_x;        // 0..21
	logic [2:0] pix_x;         // 0..4 (4 = right gap)
	logic [3:0] cell_y;        // 0..8 (9 rows)
	logic [2:0] pix_y;         // 0..5

	wire in_box_x = (h_cnt >= X_LO[10:0]) & (h_cnt < X_HI[10:0]);
	wire in_box_y = (v_cnt >= Y_LO[9:0])  & (v_cnt < Y_HI[9:0]);

	always_ff @(posedge clk_pix) begin
		if (vb_fall) begin
			cell_x <= '0;
			pix_x  <= '0;
			cell_y <= '0;
			pix_y  <= '0;
		end
		else if (hb_fall) begin
			cell_x <= '0;
			pix_x  <= '0;
			if (v_cnt + 10'd1 == Y_LO[9:0]) begin
				cell_y <= '0;
				pix_y  <= '0;
			end
			else if (v_cnt + 10'd1 > Y_LO[9:0] && v_cnt + 10'd1 < Y_HI[9:0]) begin
				if (pix_y == 3'd5) begin
					pix_y  <= '0;
					cell_y <= cell_y + 4'd1;
				end
				else pix_y <= pix_y + 3'd1;
			end
		end
		else if (ce_pix) begin
			if (in_box_x) begin
				if (pix_x == 3'd4) begin
					pix_x  <= '0;
					cell_x <= cell_x + 5'd1;
				end
				else pix_x <= pix_x + 3'd1;
			end
		end
	end

	// ---- Format + font lookups (combinational) ------------------------
	wire [5:0] glyph_id;
	wire [3:0] font_row;

	debug_overlay_format u_fmt (
`ifdef DBG_OVERLAY
		.pool    (pool),
`endif
		.cell_x  (cell_x),
		.cell_y  (cell_y),
		.glyph_id(glyph_id)
	);

	debug_font_4x6 u_font (
		.glyph (glyph_id),
		.row   (pix_y),
		.pixels(font_row)
	);

	// pix_x 0..3 select font columns (MSB = leftmost = pix_x==0); pix_x 4
	// is the inter-cell gap and is always blank.
	wire pixel_lit = visible & in_box_x & in_box_y & (pix_x < 3'd4)
	               & font_row[3 - pix_x[1:0]];

	// ---- One-stage pipeline before RGB mux ----------------------------
	logic       lit_d;
	logic [7:0] r_d, g_d, b_d;

	always_ff @(posedge clk_pix) begin
		if (ce_pix) begin
			lit_d <= pixel_lit;
			r_d   <= r_in;
			g_d   <= g_in;
			b_d   <= b_in;
		end
	end

	// Lit text uses a high-contrast yellow on transparent background.
	// Background pixels passthrough.
	always_comb begin
		if (lit_d) begin
			r_out = 8'hFF;
			g_out = 8'hF0;
			b_out = 8'h40;
		end
		else begin
			r_out = r_d;
			g_out = g_d;
			b_out = b_d;
		end
	end

endmodule
