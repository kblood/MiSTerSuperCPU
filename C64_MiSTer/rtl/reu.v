//
//	REU implementation.
// (C)2021 Alexey Melnikov
//

module reu
(
	input             clk,
	input             reset,
	input       [1:0] cfg, //none, 512K, 2MB (512KB wrap), 16MB

	output reg        dma_req,

	input             dma_cycle,
	output reg [15:0] dma_addr,
	output reg  [7:0] dma_dout,
	input       [7:0] dma_din,
	output            dma_we,
	
	input             ram_cycle,
	output reg [24:0] ram_addr,
	output reg  [7:0] ram_dout,
	input       [7:0] ram_din,
	output reg        ram_we,
	
	output reg        ram_active, // '1' during STATE_PROC_RAM (SDRAM access phase)

	input      [15:0] cpu_addr,
	input       [7:0] cpu_dout,
	output reg  [7:0] cpu_din,
	// Direct register outputs for bypass read (edge detection unreliable)
	output      [7:0] reg_status,
	output      [7:0] reg_cmd,
	output     [15:0] reg_addr_c64,
	output     [23:0] reg_addr_ram,
	output     [15:0] reg_length,
	// CPU-written snapshot registers (captured at $DFxx write, preserved across autonomous updates)
	output     [15:0] reg_addr_c64_r,
	output     [23:0] reg_addr_ram_r,
	output     [15:0] reg_length_r,
	// Command-fire diagnostics (loader.prg debugging)
	output reg [15:0] reg_cmd_count,     // incremented at STATE_IDLE→STATE_EVAL
	output reg [15:0] reg_xfer_count,    // incremented at transfer completion
	output reg  [7:0] reg_first_cmd,     // cmd byte at FIRST fire (never overwritten)
	output reg  [1:0] reg_state,         // live FSM state
	// CS edge / write/read counters (visible inside reu.v's clock domain)
	output reg [15:0] reg_cs_edges,      // # rising edges of cpu_cs seen
	output reg [15:0] reg_wr_attempts,   // # cs edges with cpu_we = 1
	output reg [15:0] reg_rd_attempts,   // # cs edges with cpu_we = 0
	output reg  [4:0] reg_last_addr_lo,  // cpu_addr[4:0] at last cs edge
	output reg  [7:0] reg_last_dout,     // cpu_dout at last cs edge
	input             cpu_we,
	input             cpu_cs,

	output reg        irq
);

reg ff00_wr;
always @(posedge clk) begin
	reg old_we;
	
	old_we <= cpu_we;
	ff00_wr <= 0;
	if(~old_we && cpu_we && cpu_addr == 'hFF00) ff00_wr <= 1;
end

localparam STATE_IDLE     = 0;
localparam STATE_EVAL     = 1;
localparam STATE_PROC_C64 = 2;
localparam STATE_PROC_RAM = 3;

reg  [19:0] op;
reg   [2:0] stage;
wire [19:0] op_cur = op >> (stage*4);
wire        op_dev = op_cur[0];   // 0: C64, 1: RAM
wire        op_dat = op_cur[1];   // storage
wire  [1:0] op_act = op_cur[3:2]; // 0: read, 1: write, 2: verify, 3: end

reg dma_we_r;
assign dma_we = dma_we_r & dma_cycle;

// Direct register read bypass (edge detection unreliable with timing violations)
assign reg_status     = {irq, status[6:5], 1'b1, 4'b0000};
assign reg_cmd        = cmd;
assign reg_addr_c64   = addr_c64;
assign reg_addr_ram   = addr_ram;
assign reg_length     = length;
assign reg_addr_c64_r = addr_c64_r;
assign reg_addr_ram_r = addr_ram_r;
assign reg_length_r   = length_r;

// Module-level register declarations (moved from always block for port access)
reg        old_cs_r;
reg  [1:0] state_r;
reg  [3:0] cnt_r;
reg  [7:0] data_r[2];
reg [15:0] addr_c64, addr_c64_r;
reg [23:0] addr_ram, addr_ram_r;
reg [15:0] length, length_r;
reg  [7:0] cmd;
reg  [7:0] intr;
reg  [7:0] ctl;
reg  [7:0] status;

always @(posedge clk) begin
	reg [23:0] addr_mask;
	reg        error;
	
	irq <= (|(status[6:5] & intr[6:5])) & intr[7];

	error = !op_act[0] && data_r[0] != data_r[1];
	addr_mask = ((cfg == 1) ? 24'h7FFFF : (cfg == 2) ? 24'h1FFFFF : 24'hFFFFFF);

	old_cs_r <= cpu_cs;

	if(reset || !cfg) begin
		status     <= 0;
		cmd        <= 'h10;
		addr_c64   <= 0;
		addr_c64_r <= 0;
		addr_ram   <= 0;
		addr_ram_r <= 0;
		length     <= 0;
		length_r   <= 0;
		intr       <= 0;
		ctl        <= 0;
		dma_req    <= 0;
		dma_we_r   <= 0;
		ram_we     <= 0;
		ram_active <= 0;
		cpu_din    <= 'hFF;
		state_r    <= STATE_IDLE;
		reg_cmd_count  <= 0;
		reg_xfer_count <= 0;
		reg_first_cmd  <= 0;
		reg_state      <= STATE_IDLE;
		reg_cs_edges     <= 0;
		reg_wr_attempts  <= 0;
		reg_rd_attempts  <= 0;
		reg_last_addr_lo <= 0;
		reg_last_dout    <= 0;
	end
	else begin
		// Internal cs edge diagnostics — count ALL edges reu.v observes
		// on its cpu_cs input (independent of dma_req gate). If reg_cs_edges
		// stays 0 during a test, the IOF chain isn't delivering a pulse at
		// all. If it ticks but reg_wr_attempts doesn't, cpu_we is 0 at the
		// rising edge (phase mismatch between cs and we).
		if(~old_cs_r & cpu_cs) begin
			reg_cs_edges     <= reg_cs_edges + 1'b1;
			reg_last_addr_lo <= cpu_addr[4:0];
			reg_last_dout    <= cpu_dout;
			if(cpu_we) reg_wr_attempts <= reg_wr_attempts + 1'b1;
			else       reg_rd_attempts <= reg_rd_attempts + 1'b1;
		end

		if(~dma_req & ~old_cs_r & cpu_cs) begin
			if(cpu_we) begin
				case(cpu_addr[4:0])
					 1:       cmd             <= cpu_dout;
					 2: begin addr_c64[7:0]   <= cpu_dout; addr_c64_r[7:0]   <= cpu_dout; end
					 3: begin addr_c64[15:8]  <= cpu_dout; addr_c64_r[15:8]  <= cpu_dout; end
					 4: begin addr_ram[7:0]   <= cpu_dout; addr_ram_r[7:0]   <= cpu_dout; end
					 5: begin addr_ram[15:8]  <= cpu_dout; addr_ram_r[15:8]  <= cpu_dout; end
					 6: begin addr_ram[23:16] <= cpu_dout; addr_ram_r[23:16] <= cpu_dout; end
					 7: begin length[7:0]     <= cpu_dout; length_r[7:0]     <= cpu_dout; end
					 8: begin length[15:8]    <= cpu_dout; length_r[15:8]    <= cpu_dout; end
					 9:       intr            <= cpu_dout;
					10:       ctl             <= cpu_dout;
				endcase
			end
			else begin
				case(cpu_addr[4:0])
					 0: begin cpu_din <= {irq, status[6:5], 1'b1, 4'b0000}; status <= 0; end
					 1: cpu_din <= cmd;
					 2: cpu_din <= addr_c64[7:0];
					 3: cpu_din <= addr_c64[15:8];
					 4: cpu_din <= addr_ram[7:0];
					 5: cpu_din <= addr_ram[15:8];
					 6: cpu_din <= addr_ram[23:16] | ~addr_mask[23:16];
					 7: cpu_din <= length[7:0];
					 8: cpu_din <= length[15:8];
					 9: cpu_din <= {intr[7:5],5'h1F};
					10: cpu_din <= {ctl[7:6],6'h3F};
				default: cpu_din <= 'hFF;
				endcase
			end
		end
	
		case(state_r)
			STATE_IDLE:
				if(cmd[7] & (cmd[4] | ff00_wr)) begin
					case(cmd[1:0])
						0: op <= 'b1100_1100_1100_0101_0000; // C64 --> RAM
						1: op <= 'b1100_1100_1100_0100_0001; // C64 <-- RAM
						2: op <= 'b1100_0110_0101_0000_0011; // C64 <-> RAM
						3: op <= 'b1100_1100_1000_0000_0011; // C64 =?= RAM
					endcase
					dma_req    <= 1;
					stage      <= 0;
					state_r    <= STATE_EVAL;
					addr_ram   <= addr_ram & addr_mask;
					addr_ram_r <= addr_ram_r & addr_mask;
					// Diagnostic: count command fires, capture FIRST cmd byte
					reg_cmd_count <= reg_cmd_count + 1'b1;
					if (reg_cmd_count == 16'd0) reg_first_cmd <= cmd;
				end

			STATE_EVAL:
				begin
					cnt_r <= 0;
					if(op_act[1]) begin
						if(~ctl[7]) addr_c64 <= addr_c64 + 1'd1;
						if(~ctl[6]) addr_ram <= (cfg == 2) ? {addr_ram[20:19], addr_ram[18:0] + 1'd1} : ((addr_ram + 1'd1) & addr_mask);
						stage <= 0;
						if(length == 1 || error) begin
							if(cmd[5]) begin
								addr_ram <= addr_ram_r;
								addr_c64 <= addr_c64_r;
								length   <= length_r;
							end
							status[6] <= 1;
							if(error) status[5] <= 1;
							cmd[4]    <= 1;
							cmd[7]    <= 0;
							dma_req   <= 0;
							state_r <= STATE_IDLE;
							// Diagnostic: count transfer completions
							reg_xfer_count <= reg_xfer_count + 1'b1;
						end
						else length  <= length - 1'd1;
					end
					else if(op_dev) begin
						if (~ram_cycle) begin
							ram_addr  <= {1'b1, addr_ram};
							ram_we    <= op_act[0];
							ram_dout  <= data_r[op_dat];
							ram_active <= 1;
							state_r <= STATE_PROC_RAM;
						end
					end
					else begin
						if(~dma_cycle) begin
							dma_addr  <= addr_c64;
							dma_we_r  <= op_act[0];
							dma_dout  <= data_r[op_dat];
							state_r <= STATE_PROC_C64;
						end
					end
				end

			STATE_PROC_RAM:
				if(ram_cycle) begin
					cnt_r    <= cnt_r + 1'd1;
					if(&cnt_r[1:0]) begin
						data_r[op_dat] <= ram_din;
						ram_we       <= 0;
						ram_active   <= 0;
						stage        <= stage + 1'd1;
						state_r <= STATE_EVAL;
					end
				end

			STATE_PROC_C64:
				if(dma_cycle) begin
					cnt_r <= cnt_r + 1'd1;
					if(&cnt_r[3:0]) begin
						dma_addr     <= 0; // make sure we won't read some device's data while idling.
						dma_we_r     <= 0;
						data_r[op_dat] <= dma_din;
						stage        <= stage + 1'd1;
						state_r <= STATE_EVAL;
					end
				end
		endcase
		// Live mirror of FSM state for diagnostics ($DFB5)
		reg_state <= state_r;
	end
end

endmodule
