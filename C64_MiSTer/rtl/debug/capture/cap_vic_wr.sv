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
	input  logic [23:0] in_dd00_pc,
	input  logic  [7:0] in_dd00_count,
	input  logic [23:0] in_dd00_pc_v0,
	input  logic [23:0] in_dd00_pc_v1,
	input  logic [23:0] in_dd00_pc_v2,
	input  logic [23:0] in_dd00_pc_v3,
	input  logic  [7:0] in_dd00_cnt_v0,
	input  logic  [7:0] in_dd00_cnt_v1,
	input  logic  [7:0] in_dd00_cnt_v2,
	input  logic  [7:0] in_dd00_cnt_v3,
	input  logic [23:0] in_d018_last_pc,
	input  logic  [7:0] in_d018_count,
	input  logic [23:0] in_d018_bad_pc,
	input  logic  [7:0] in_d018_bad_count,
	input  logic  [7:0] in_d018_bad_value,
	input  logic [23:0] in_trace_pc0,
	input  logic [23:0] in_trace_pc1,
	input  logic [23:0] in_trace_pc2,
	input  logic [23:0] in_trace_pc3,
	input  logic        in_trace_frozen,

	output logic  [7:0] o_d018,
	output logic  [7:0] o_d016,
	output logic  [7:0] o_dd00,
	output logic [11:0] o_raster,
	output logic [23:0] o_dd00_pc,
	output logic  [7:0] o_dd00_count,
	output logic [23:0] o_dd00_pc_v0,
	output logic [23:0] o_dd00_pc_v1,
	output logic [23:0] o_dd00_pc_v2,
	output logic [23:0] o_dd00_pc_v3,
	output logic  [7:0] o_dd00_cnt_v0,
	output logic  [7:0] o_dd00_cnt_v1,
	output logic  [7:0] o_dd00_cnt_v2,
	output logic  [7:0] o_dd00_cnt_v3,
	output logic [23:0] o_d018_last_pc,
	output logic  [7:0] o_d018_count,
	output logic [23:0] o_d018_bad_pc,
	output logic  [7:0] o_d018_bad_count,
	output logic  [7:0] o_d018_bad_value,
	output logic [23:0] o_trace_pc0,
	output logic [23:0] o_trace_pc1,
	output logic [23:0] o_trace_pc2,
	output logic [23:0] o_trace_pc3,
	output logic        o_trace_frozen
);

	assign o_d018        = in_d018;
	assign o_d016        = in_d016;
	assign o_dd00        = in_dd00;
	assign o_raster      = {3'b000, in_raster};
	assign o_dd00_pc     = in_dd00_pc;
	assign o_dd00_count  = in_dd00_count;
	assign o_dd00_pc_v0  = in_dd00_pc_v0;
	assign o_dd00_pc_v1  = in_dd00_pc_v1;
	assign o_dd00_pc_v2  = in_dd00_pc_v2;
	assign o_dd00_pc_v3  = in_dd00_pc_v3;
	assign o_dd00_cnt_v0 = in_dd00_cnt_v0;
	assign o_dd00_cnt_v1 = in_dd00_cnt_v1;
	assign o_dd00_cnt_v2 = in_dd00_cnt_v2;
	assign o_dd00_cnt_v3 = in_dd00_cnt_v3;
	assign o_d018_last_pc   = in_d018_last_pc;
	assign o_d018_count     = in_d018_count;
	assign o_d018_bad_pc    = in_d018_bad_pc;
	assign o_d018_bad_count = in_d018_bad_count;
	assign o_d018_bad_value = in_d018_bad_value;
	assign o_trace_pc0      = in_trace_pc0;
	assign o_trace_pc1      = in_trace_pc1;
	assign o_trace_pc2      = in_trace_pc2;
	assign o_trace_pc3      = in_trace_pc3;
	assign o_trace_frozen   = in_trace_frozen;

endmodule
