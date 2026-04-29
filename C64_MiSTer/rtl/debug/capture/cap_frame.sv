// cap_frame.sv
//
// 16-bit frame counter, incremented on the rising edge of vsync. Wraps
// silently. Used by overlays to detect "is the frame still ticking?".

module cap_frame (
	input  logic        clk,
	input  logic        rst,
	input  logic        vsync,

	output logic [15:0] o_frame_count
);

	logic vs_d;
	logic [15:0] cnt;

	always_ff @(posedge clk) begin
		if (rst) begin
			cnt  <= '0;
			vs_d <= 1'b0;
		end
		else begin
			vs_d <= vsync;
			if (vsync & ~vs_d) cnt <= cnt + 16'd1;
		end
	end

	assign o_frame_count = cnt;

endmodule
