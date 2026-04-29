// debug_overlay_renderer.sv
//
// Pixel-rate overlay renderer that injects a small diagnostic box near
// the top of the frame. Commit 3 paints a solid blue 110x27 box at
// (X 4..113, Y 6..32) when the runtime visibility bit is set; commits
// 4-6 add the 4x6 font cascade and per-cell character rendering.
//
// Pipeline:
//   - Maintain internal H/V counters using rising edges of hsync/vsync.
//     The C64 sync wires are in the clk32 domain but their pulses are
//     many CLK_VIDEO cycles wide, so a one-stage edge detector on
//     CLK_VIDEO is sufficient.
//   - Compute "in_box" combinationally on H/V.
//   - Pipeline (in_box, r/g/b passthrough) one cycle before the RGB mux
//     so future commits can absorb font-lookup combinational delay.
//
// When `\`undef DBG_OVERLAY` (release build) the parent c64.sv selects
// the passthrough branch and this module is never instantiated.

module debug_overlay_renderer #(
	parameter int X_LO = 4,
	parameter int X_HI = 113,   // exclusive: hits 110 px wide
	parameter int Y_LO = 6,
	parameter int Y_HI = 32     // exclusive: hits 26 px tall
) (
	input  logic       clk_pix,    // CLK_VIDEO (= clk64)
	input  logic       ce_pix,     // pixel enable

	input  logic       hsync,      // C64 internal hsync (clk32 domain)
	input  logic       vsync,      // C64 internal vsync (clk32 domain)

	input  logic       visible,    // runtime show/hide (status[83])

	input  logic [7:0] r_in,
	input  logic [7:0] g_in,
	input  logic [7:0] b_in,

	output logic [7:0] r_out,
	output logic [7:0] g_out,
	output logic [7:0] b_out
);

	// ---- Sync edge detection ------------------------------------------
	logic hs_d, vs_d;
	logic hs_rise, vs_rise;

	always_ff @(posedge clk_pix) begin
		hs_d <= hsync;
		vs_d <= vsync;
	end

	assign hs_rise = hsync & ~hs_d;
	assign vs_rise = vsync & ~vs_d;

	// ---- H/V counters -------------------------------------------------
	logic [10:0] h_cnt;
	logic [9:0]  v_cnt;

	always_ff @(posedge clk_pix) begin
		if (hs_rise) begin
			h_cnt <= '0;
			v_cnt <= vs_rise ? 10'd0 : (v_cnt + 10'd1);
		end
		else if (ce_pix) begin
			h_cnt <= h_cnt + 11'd1;
		end
	end

	// ---- Box geometry -------------------------------------------------
	wire in_box = visible
	            & (h_cnt >= X_LO[10:0]) & (h_cnt < X_HI[10:0])
	            & (v_cnt >= Y_LO[9:0])  & (v_cnt < Y_HI[9:0]);

	// ---- Single-stage pipeline before RGB mux -------------------------
	logic       in_box_d;
	logic [7:0] r_d, g_d, b_d;

	always_ff @(posedge clk_pix) begin
		if (ce_pix) begin
			in_box_d <= in_box;
			r_d      <= r_in;
			g_d      <= g_in;
			b_d      <= b_in;
		end
	end

	// Solid C64-blue test fill while bringing pixel injection up.
	always_comb begin
		if (in_box_d) begin
			r_out = 8'h35;
			g_out = 8'h28;
			b_out = 8'hB2;
		end
		else begin
			r_out = r_d;
			g_out = g_d;
			b_out = b_d;
		end
	end

endmodule
