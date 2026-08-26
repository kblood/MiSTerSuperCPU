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
	input  logic  [7:0] in_d011,
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
	input  logic  [7:0] in_trace_op0,
	input  logic  [7:0] in_trace_op1,
	input  logic  [7:0] in_trace_op2,
	input  logic  [7:0] in_trace_op3,
	input  logic        in_trace_frozen,
	input  logic [23:0] in_trace_pc4,
	input  logic [23:0] in_trace_pc5,
	input  logic  [7:0] in_trace_op4,
	input  logic  [7:0] in_trace_op5,
	input  logic [23:0] in_scr_write_pc,
	input  logic  [7:0] in_scr_write_count,
	input  logic [23:0] in_trace_pc6,
	input  logic [23:0] in_trace_pc7,
	input  logic  [7:0] in_trace_op6,
	input  logic  [7:0] in_trace_op7,
	input  logic [15:0] in_scr_write_jsr_a,
	input  logic [15:0] in_scr_write_jsr_b,
	input  logic [15:0] in_jsr_pc_t0,
	input  logic [15:0] in_jsr_pc_t1,
	input  logic [15:0] in_jsr_pc_t2,
	input  logic [15:0] in_jsr_pc_t3,
	input  logic [15:0] in_jmp_tgt_t0,
	input  logic [15:0] in_jmp_tgt_t1,
	input  logic [15:0] in_jmp_tgt_t2,
	input  logic [15:0] in_jmp_tgt_t3,
	input  logic  [7:0] in_mem_0314,
	input  logic  [7:0] in_mem_0315,
	input  logic  [7:0] in_mem_00,
	input  logic  [7:0] in_mem_01,
	input  logic [23:0] in_op_count,
	input  logic  [7:0] in_cur_op,

	output logic  [7:0] o_d018,
	output logic  [7:0] o_d016,
	output logic  [7:0] o_dd00,
	output logic  [7:0] o_d011,
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
	output logic  [7:0] o_trace_op0,
	output logic  [7:0] o_trace_op1,
	output logic  [7:0] o_trace_op2,
	output logic  [7:0] o_trace_op3,
	output logic        o_trace_frozen,
	output logic [23:0] o_trace_pc4,
	output logic [23:0] o_trace_pc5,
	output logic  [7:0] o_trace_op4,
	output logic  [7:0] o_trace_op5,
	output logic [23:0] o_scr_write_pc,
	output logic  [7:0] o_scr_write_count,
	output logic [23:0] o_trace_pc6,
	output logic [23:0] o_trace_pc7,
	output logic  [7:0] o_trace_op6,
	output logic  [7:0] o_trace_op7,
	output logic [15:0] o_scr_write_jsr_a,
	output logic [15:0] o_scr_write_jsr_b,
	output logic [15:0] o_jsr_pc_t0,
	output logic [15:0] o_jsr_pc_t1,
	output logic [15:0] o_jsr_pc_t2,
	output logic [15:0] o_jsr_pc_t3,
	output logic [15:0] o_jmp_tgt_t0,
	output logic [15:0] o_jmp_tgt_t1,
	output logic [15:0] o_jmp_tgt_t2,
	output logic [15:0] o_jmp_tgt_t3,
	output logic  [7:0] o_mem_0314,
	output logic  [7:0] o_mem_0315,
	output logic  [7:0] o_mem_00,
	output logic  [7:0] o_mem_01,
	output logic [23:0] o_op_count,
	output logic  [7:0] o_cur_op
);

	assign o_d018        = in_d018;
	assign o_d016        = in_d016;
	assign o_dd00        = in_dd00;
	assign o_d011        = in_d011;
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
	assign o_trace_op0      = in_trace_op0;
	assign o_trace_op1      = in_trace_op1;
	assign o_trace_op2      = in_trace_op2;
	assign o_trace_op3      = in_trace_op3;
	assign o_trace_frozen   = in_trace_frozen;
	assign o_trace_pc4      = in_trace_pc4;
	assign o_trace_pc5      = in_trace_pc5;
	assign o_trace_op4      = in_trace_op4;
	assign o_trace_op5      = in_trace_op5;
	assign o_scr_write_pc    = in_scr_write_pc;
	assign o_scr_write_count = in_scr_write_count;
	assign o_trace_pc6      = in_trace_pc6;
	assign o_trace_pc7      = in_trace_pc7;
	assign o_trace_op6      = in_trace_op6;
	assign o_trace_op7      = in_trace_op7;
	assign o_scr_write_jsr_a = in_scr_write_jsr_a;
	assign o_scr_write_jsr_b = in_scr_write_jsr_b;
	assign o_jsr_pc_t0      = in_jsr_pc_t0;
	assign o_jsr_pc_t1      = in_jsr_pc_t1;
	assign o_jsr_pc_t2      = in_jsr_pc_t2;
	assign o_jsr_pc_t3      = in_jsr_pc_t3;
	assign o_jmp_tgt_t0     = in_jmp_tgt_t0;
	assign o_jmp_tgt_t1     = in_jmp_tgt_t1;
	assign o_jmp_tgt_t2     = in_jmp_tgt_t2;
	assign o_jmp_tgt_t3     = in_jmp_tgt_t3;
	assign o_mem_0314       = in_mem_0314;
	assign o_mem_0315       = in_mem_0315;
	assign o_mem_00         = in_mem_00;
	assign o_mem_01         = in_mem_01;
	assign o_op_count       = in_op_count;
	assign o_cur_op         = in_cur_op;

endmodule
