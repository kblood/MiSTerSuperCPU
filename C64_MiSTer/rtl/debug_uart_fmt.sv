// debug_uart_fmt.sv - Formats CPU debug state as ASCII hex lines over UART
//
// Sends one line per frame (at vblank) containing CPU state:
//   A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx\n
//
// Fields:
//   A = CPU address (16-bit)
//   K = PBR - Program Bank Register (8-bit)
//   B = Address bus bank byte (8-bit, A23-A16)
//   S = Stack pointer (16-bit)
//   P = Processor status (8-bit)
//   I = Instruction register / opcode (8-bit)
//   E = Emulation mode (1-bit)
//   F = Frame counter (16-bit, for freeze detection)
//   T = Diag byte: b0=turbo,b1=rom_vis,b2=1mhz,b3=iec,b4=overlay,b5=cache,b6=enCpu
//   C = Cache hit count per frame (16-bit)
//   N = enableCpu count per frame (16-bit)
//
// At 115200 baud, each line is ~63 chars = ~5.5ms. One line per frame
// (50Hz PAL / 60Hz NTSC) = well within bandwidth.

module debug_uart_fmt (
	input         clk,
	input         reset,
	input         enable,     // from OSD toggle

	// Debug data inputs (directly from core, latched internally at vblank)
	input         vblank,     // vblank edge triggers a new line
	input  [15:0] cpu_addr,
	input   [7:0] cpu_data,
	input   [7:0] cpu_bank,
	input  [15:0] cpu_sp,
	input   [7:0] cpu_p,
	input   [7:0] cpu_ir,
	input         cpu_emul,
	input   [7:0] cpu_pbr,      // Program Bank Register
	input   [7:0] cpu_dbr,      // Data Bank Register

	// Turbo/cache diagnostics (active signals, counted per frame)
	input         turbo_en,
	input   [7:0] diag,         // diagnostic byte: b0=turbo,b1=rom_vis,b2=1mhz,b3=iec,b4=overlay,b5=cache,b6=enCpu
	input         cache_hit_pulse,
	input         enable_cpu_pulse,
	input         cpu_cyc_pulse,

	// UART TX interface
	output reg [7:0] tx_data,
	output reg       tx_send,
	input            tx_busy
);

// Frame counter (increments each vblank)
reg [15:0] frame_cnt;

// Latch debug data at vblank for stable output
reg [15:0] lat_addr;
reg  [7:0] lat_data;
reg  [7:0] lat_bank;
reg [15:0] lat_sp;
reg  [7:0] lat_p;
reg  [7:0] lat_ir;
reg        lat_emul;
reg  [7:0] lat_pbr;
reg  [7:0] lat_dbr;
reg [15:0] lat_frame;
reg        lat_turbo;
reg  [7:0] lat_diag;
reg [19:0] lat_ch_cnt;
reg [19:0] lat_en_cnt;

// Per-frame counters (running, latched at vblank)
// 20-bit to avoid 16-bit wrapping (max ~628k cycles/frame)
reg [19:0] ch_cnt;
reg [19:0] en_cnt;
reg [19:0] cy_cnt;
reg [19:0] lat_cy_cnt;

// State machine
reg        vblank_r;
reg        sending;       // currently sending a line
reg [6:0]  char_idx;      // character position within the line
reg        char_pending;  // a character is ready to send

// Line format: "A:xxxx D:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx\n"
// Total: 62 characters + \n = 63 characters
// Character positions (0-indexed):
//  0  A
//  1  :
//  2-5 addr hex
//  6  space
//  7  D
//  8  :
//  9-10 data hex
// 11  space
// 12  B
// 13  :
// 14-15 bank hex
// 16  space
// 17  S
// 18  :
// 19-22 sp hex
// 23  space
// 24  P
// 25  :
// 26-27 p hex
// 28  space
// 29  I
// 30  :
// 31-32 ir hex
// 33  space
// 34  E
// 35  :
// 36  emul hex
// 37  space
// 38  F
// 39  :
// 40-43 frame hex
// 44  space
// 45  T
// 46  :
// 47-48 diag hex (2 digits)
// 49  space
// 50  C
// 51  :
// 52-55 cache hit count hex
// 56  space
// 57  N
// 58  :
// 59-62 enable count hex
// 63  \n
localparam LINE_LEN = 7'd64;

// Hex nibble to ASCII
function [7:0] hex_char;
	input [3:0] nibble;
	hex_char = (nibble < 4'd10) ? (8'h30 + {4'b0, nibble}) : (8'h41 + {4'b0, nibble} - 8'd10);
endfunction

// Character lookup
reg [7:0] line_char;

always @(*) begin
	case (char_idx)
		7'd0:  line_char = "A";
		7'd1:  line_char = ":";
		7'd2:  line_char = hex_char(lat_addr[15:12]);
		7'd3:  line_char = hex_char(lat_addr[11:8]);
		7'd4:  line_char = hex_char(lat_addr[7:4]);
		7'd5:  line_char = hex_char(lat_addr[3:0]);
		7'd6:  line_char = " ";
		7'd7:  line_char = "K";  // K = PBR (program bank register)
		7'd8:  line_char = ":";
		7'd9:  line_char = hex_char(lat_pbr[7:4]);
		7'd10: line_char = hex_char(lat_pbr[3:0]);
		7'd11: line_char = " ";
		7'd12: line_char = "B";
		7'd13: line_char = ":";
		7'd14: line_char = hex_char(lat_bank[7:4]);
		7'd15: line_char = hex_char(lat_bank[3:0]);
		7'd16: line_char = " ";
		7'd17: line_char = "S";  // S = Stack pointer (16-bit)
		7'd18: line_char = ":";
		7'd19: line_char = hex_char(lat_sp[15:12]);
		7'd20: line_char = hex_char(lat_sp[11:8]);
		7'd21: line_char = hex_char(lat_sp[7:4]);
		7'd22: line_char = hex_char(lat_sp[3:0]);
		7'd23: line_char = " ";
		7'd24: line_char = "P";
		7'd25: line_char = ":";
		7'd26: line_char = hex_char(lat_p[7:4]);
		7'd27: line_char = hex_char(lat_p[3:0]);
		7'd28: line_char = " ";
		7'd29: line_char = "I";
		7'd30: line_char = ":";
		7'd31: line_char = hex_char(lat_ir[7:4]);
		7'd32: line_char = hex_char(lat_ir[3:0]);
		7'd33: line_char = " ";
		7'd34: line_char = "E";
		7'd35: line_char = ":";
		7'd36: line_char = hex_char({3'b0, lat_emul});
		7'd37: line_char = " ";
		7'd38: line_char = "F";
		7'd39: line_char = ":";
		7'd40: line_char = hex_char(lat_frame[15:12]);
		7'd41: line_char = hex_char(lat_frame[11:8]);
		7'd42: line_char = hex_char(lat_frame[7:4]);
		7'd43: line_char = hex_char(lat_frame[3:0]);
		7'd44: line_char = " ";
		7'd45: line_char = "T";
		7'd46: line_char = ":";
		7'd47: line_char = hex_char(lat_diag[7:4]);
		7'd48: line_char = hex_char(lat_diag[3:0]);
		7'd49: line_char = " ";
		7'd50: line_char = "C";
		7'd51: line_char = ":";
		7'd52: line_char = hex_char(lat_ch_cnt[19:16]);
		7'd53: line_char = hex_char(lat_ch_cnt[15:12]);
		7'd54: line_char = hex_char(lat_ch_cnt[11:8]);
		7'd55: line_char = hex_char(lat_ch_cnt[7:4]);
		7'd56: line_char = " ";
		7'd57: line_char = "N";
		7'd58: line_char = ":";
		7'd59: line_char = hex_char(lat_en_cnt[19:16]);
		7'd60: line_char = hex_char(lat_en_cnt[15:12]);
		7'd61: line_char = hex_char(lat_en_cnt[11:8]);
		7'd62: line_char = hex_char(lat_en_cnt[7:4]);
		7'd63: line_char = 8'h0A;  // newline
		default: line_char = " ";
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		sending     <= 0;
		char_idx    <= 0;
		tx_send     <= 0;
		char_pending <= 0;
		frame_cnt   <= 0;
		vblank_r    <= 0;
		ch_cnt      <= 0;
		en_cnt      <= 0;
		cy_cnt      <= 0;
	end
	else begin
		vblank_r <= vblank;
		tx_send  <= 0;

		// Per-frame pulse counters
		if (cache_hit_pulse)
			ch_cnt <= ch_cnt + 1'b1;
		if (enable_cpu_pulse)
			en_cnt <= en_cnt + 1'b1;
		if (cpu_cyc_pulse)
			cy_cnt <= cy_cnt + 1'b1;

		// Detect vblank rising edge → latch data and start sending
		if (vblank && !vblank_r && enable && !sending) begin
			lat_addr   <= cpu_addr;
			lat_data   <= cpu_data;
			lat_bank   <= cpu_bank;
			lat_sp     <= cpu_sp;
			lat_p      <= cpu_p;
			lat_ir     <= cpu_ir;
			lat_emul   <= cpu_emul;
			lat_pbr    <= cpu_pbr;
			lat_dbr    <= cpu_dbr;
			lat_frame  <= frame_cnt;
			lat_turbo  <= turbo_en;
			lat_diag   <= diag;
			lat_ch_cnt <= ch_cnt;
			lat_en_cnt <= en_cnt;
			lat_cy_cnt <= cy_cnt;
			frame_cnt  <= frame_cnt + 1'b1;
			ch_cnt     <= 0;
			en_cnt     <= 0;
			cy_cnt     <= 0;

			sending      <= 1;
			char_idx     <= 0;
			char_pending <= 1;
		end

		// Send characters one at a time
		if (sending && char_pending && !tx_busy) begin
			tx_data      <= line_char;
			tx_send      <= 1;
			char_pending <= 0;
		end

		// After tx_send, advance to next character
		if (sending && !char_pending && !tx_busy && !tx_send) begin
			if (char_idx == LINE_LEN - 1'b1) begin
				sending <= 0;
			end
			else begin
				char_idx     <= char_idx + 1'b1;
				char_pending <= 1;
			end
		end
	end
end

endmodule
