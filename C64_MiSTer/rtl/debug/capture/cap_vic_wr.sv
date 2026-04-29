// cap_vic_wr.sv
//
// Forwards the VIC / CIA2 write latches and the live raster line driven
// out of fpga64_sid_iec into the pool. The latches are already done
// inside fpga64 (cs_vic + cpuWe + cpuAddr decode); here we just route
// the values through.

module cap_vic_wr (
	input  logic        clk,
	input  logic        rst,

	input  logic  [7:0] in_d018,
	input  logic  [7:0] in_d016,
	input  logic  [7:0] in_dd00,
	input  logic  [8:0] in_raster,

	output logic  [7:0] o_d018,
	output logic  [7:0] o_d016,
	output logic  [7:0] o_dd00,
	output logic [11:0] o_raster
);

	assign o_d018   = in_d018;
	assign o_d016   = in_d016;
	assign o_dd00   = in_dd00;
	assign o_raster = {3'b000, in_raster};

endmodule
