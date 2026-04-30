// cap_cpu_state.sv
//
// Forwards muxed CPU PC + P + DBR + a packed flags byte into the pool.
// PC mux happens upstream in fpga64_sid_iec.vhd (T65 cpuAddr or P65C816
// {PBR,PC} based on supercpu_en). P and DBR are P65C816-only (zero when
// T65 active) and are used to detect emu-mode flag drift in DL triage.
// Flags byte aggregates BA, DMA, SCPU, emulation, and turbo state from
// the existing top-level wires.

module cap_cpu_state (
	input  logic        clk,
	input  logic        rst,

	input  logic [23:0] in_pc,
	input  logic  [7:0] in_p,
	input  logic  [7:0] in_dbr,
	input  logic        in_supercpu_en,
	input  logic        in_emu_mode,
	input  logic        in_dma_active,
	input  logic        in_ba,

	output logic [23:0] o_pc,
	output logic  [7:0] o_p,
	output logic  [7:0] o_dbr,
	output logic  [7:0] o_flags
);

	assign o_pc    = in_pc;
	assign o_p     = in_p;
	assign o_dbr   = in_dbr;
	assign o_flags = {3'b000, in_supercpu_en, in_emu_mode, in_dma_active, in_ba, 1'b0};

endmodule
