// debug_uart_fmt.sv - Formats CPU debug state as ASCII hex lines over UART
//
// Sends one line per frame (at vblank) containing CPU state:
//   A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx W:xxxx L:xx[!/.]\n
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

	// Crash diagnostics
	input  [15:0] native_irq_vec,   // native IRQ vector value ($FFEE/$FFEF)
	input   [7:0] crash_bank,       // first unexpected PBR (crash bank latch)
	input         vic_irq,          // VIC IRQ asserted (active high)

	// Crash trace ring buffer
	// Layout (641 bytes = 5128 bits):
	//   [7:0]       status (bit0 = frozen, bits[7:1] = wp[6:0])
	//   [4103:8]    128 × (PC_lo, PC_hi, PBR, IR) — 4 bytes per entry
	//   [5127:4104] 128 × P byte — one per entry, appended
	input [5127:0] trace_buf,

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
reg [15:0] lat_irq_vec;
reg  [7:0] lat_crash_bank;
reg        lat_vic_irq;

// Crash trace stream: one entry per vblank when trace is frozen.
// trace_idx cycles 0..127 through the ring buffer after freeze trips.
reg  [6:0] trace_idx;
reg        lat_frozen;
reg  [6:0] lat_trace_idx;
reg [31:0] lat_trace_entry;  // {IR, PBR, PC_hi, PC_lo}
reg  [7:0] lat_trace_p;      // P register for the selected entry

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

// Line format: "A:xxxx K:xx B:xx S:xxxx P:xx I:xx E:x F:xxxx T:xx C:xxxx N:xxxx V:xxxx L:xx.\n"
// Total: 77 characters + \n = 78 characters
// Character positions (0-indexed):
//  0-5   A:xxxx
//  6     space
//  7-10  K:xx (PBR)
// 11     space
// 12-15  B:xx (bank)
// 16     space
// 17-22  S:xxxx
// 23     space
// 24-27  P:xx
// 28     space
// 29-32  I:xx
// 33     space
// 34-36  E:x
// 37     space
// 38-43  F:xxxx
// 44     space
// 45-48  T:xx
// 49     space
// 50-55  C:xxxx (20-bit, show top 16)
// 56     space
// 57-62  N:xxxx (20-bit, show top 16)
// 63     space
// 64-69  V:xxxx (native IRQ vector)
// 70     space
// 71-74  L:xx (crash bank latch)
// 75     !/. (VIC IRQ indicator)
// 76     ' ' when frozen (to continue line), '\n' when not
// --- Crash trace extension (only emitted when lat_frozen=1) ---
// 77-81  TR:xx (trace_idx 0..31)
// 82     space
// 83-89  PC:xxxx
// 90     space
// 91-94  K:xx
// 95     space
// 96-99  I:xx
// 100    space
// 101-104 P:xx
// 105    \n
localparam LINE_LEN_NORMAL = 7'd77;
localparam LINE_LEN_FROZEN = 7'd106;
wire [6:0] line_len_cur = lat_frozen ? LINE_LEN_FROZEN : LINE_LEN_NORMAL;

// Hex nibble to ASCII
function [7:0] hex_char;
	input [3:0] nibble;
	hex_char = (nibble < 4'd10) ? (8'h30 + {4'b0, nibble}) : (8'h41 + {4'b0, nibble} - 8'd10);
endfunction

// Combinational mux: select one of 128 trace entries using constant part-selects.
// Avoids variable part-select (which crashed Quartus 17 Analysis & Synthesis).
reg [31:0] trace_entry_sel;
always @(*) begin
	case (trace_idx)
		7'd0:   trace_entry_sel = trace_buf[  39:   8];
		7'd1:   trace_entry_sel = trace_buf[  71:  40];
		7'd2:   trace_entry_sel = trace_buf[ 103:  72];
		7'd3:   trace_entry_sel = trace_buf[ 135: 104];
		7'd4:   trace_entry_sel = trace_buf[ 167: 136];
		7'd5:   trace_entry_sel = trace_buf[ 199: 168];
		7'd6:   trace_entry_sel = trace_buf[ 231: 200];
		7'd7:   trace_entry_sel = trace_buf[ 263: 232];
		7'd8:   trace_entry_sel = trace_buf[ 295: 264];
		7'd9:   trace_entry_sel = trace_buf[ 327: 296];
		7'd10:  trace_entry_sel = trace_buf[ 359: 328];
		7'd11:  trace_entry_sel = trace_buf[ 391: 360];
		7'd12:  trace_entry_sel = trace_buf[ 423: 392];
		7'd13:  trace_entry_sel = trace_buf[ 455: 424];
		7'd14:  trace_entry_sel = trace_buf[ 487: 456];
		7'd15:  trace_entry_sel = trace_buf[ 519: 488];
		7'd16:  trace_entry_sel = trace_buf[ 551: 520];
		7'd17:  trace_entry_sel = trace_buf[ 583: 552];
		7'd18:  trace_entry_sel = trace_buf[ 615: 584];
		7'd19:  trace_entry_sel = trace_buf[ 647: 616];
		7'd20:  trace_entry_sel = trace_buf[ 679: 648];
		7'd21:  trace_entry_sel = trace_buf[ 711: 680];
		7'd22:  trace_entry_sel = trace_buf[ 743: 712];
		7'd23:  trace_entry_sel = trace_buf[ 775: 744];
		7'd24:  trace_entry_sel = trace_buf[ 807: 776];
		7'd25:  trace_entry_sel = trace_buf[ 839: 808];
		7'd26:  trace_entry_sel = trace_buf[ 871: 840];
		7'd27:  trace_entry_sel = trace_buf[ 903: 872];
		7'd28:  trace_entry_sel = trace_buf[ 935: 904];
		7'd29:  trace_entry_sel = trace_buf[ 967: 936];
		7'd30:  trace_entry_sel = trace_buf[ 999: 968];
		7'd31:  trace_entry_sel = trace_buf[1031:1000];
		7'd32:  trace_entry_sel = trace_buf[1063:1032];
		7'd33:  trace_entry_sel = trace_buf[1095:1064];
		7'd34:  trace_entry_sel = trace_buf[1127:1096];
		7'd35:  trace_entry_sel = trace_buf[1159:1128];
		7'd36:  trace_entry_sel = trace_buf[1191:1160];
		7'd37:  trace_entry_sel = trace_buf[1223:1192];
		7'd38:  trace_entry_sel = trace_buf[1255:1224];
		7'd39:  trace_entry_sel = trace_buf[1287:1256];
		7'd40:  trace_entry_sel = trace_buf[1319:1288];
		7'd41:  trace_entry_sel = trace_buf[1351:1320];
		7'd42:  trace_entry_sel = trace_buf[1383:1352];
		7'd43:  trace_entry_sel = trace_buf[1415:1384];
		7'd44:  trace_entry_sel = trace_buf[1447:1416];
		7'd45:  trace_entry_sel = trace_buf[1479:1448];
		7'd46:  trace_entry_sel = trace_buf[1511:1480];
		7'd47:  trace_entry_sel = trace_buf[1543:1512];
		7'd48:  trace_entry_sel = trace_buf[1575:1544];
		7'd49:  trace_entry_sel = trace_buf[1607:1576];
		7'd50:  trace_entry_sel = trace_buf[1639:1608];
		7'd51:  trace_entry_sel = trace_buf[1671:1640];
		7'd52:  trace_entry_sel = trace_buf[1703:1672];
		7'd53:  trace_entry_sel = trace_buf[1735:1704];
		7'd54:  trace_entry_sel = trace_buf[1767:1736];
		7'd55:  trace_entry_sel = trace_buf[1799:1768];
		7'd56:  trace_entry_sel = trace_buf[1831:1800];
		7'd57:  trace_entry_sel = trace_buf[1863:1832];
		7'd58:  trace_entry_sel = trace_buf[1895:1864];
		7'd59:  trace_entry_sel = trace_buf[1927:1896];
		7'd60:  trace_entry_sel = trace_buf[1959:1928];
		7'd61:  trace_entry_sel = trace_buf[1991:1960];
		7'd62:  trace_entry_sel = trace_buf[2023:1992];
		7'd63:  trace_entry_sel = trace_buf[2055:2024];
		7'd64:  trace_entry_sel = trace_buf[2087:2056];
		7'd65:  trace_entry_sel = trace_buf[2119:2088];
		7'd66:  trace_entry_sel = trace_buf[2151:2120];
		7'd67:  trace_entry_sel = trace_buf[2183:2152];
		7'd68:  trace_entry_sel = trace_buf[2215:2184];
		7'd69:  trace_entry_sel = trace_buf[2247:2216];
		7'd70:  trace_entry_sel = trace_buf[2279:2248];
		7'd71:  trace_entry_sel = trace_buf[2311:2280];
		7'd72:  trace_entry_sel = trace_buf[2343:2312];
		7'd73:  trace_entry_sel = trace_buf[2375:2344];
		7'd74:  trace_entry_sel = trace_buf[2407:2376];
		7'd75:  trace_entry_sel = trace_buf[2439:2408];
		7'd76:  trace_entry_sel = trace_buf[2471:2440];
		7'd77:  trace_entry_sel = trace_buf[2503:2472];
		7'd78:  trace_entry_sel = trace_buf[2535:2504];
		7'd79:  trace_entry_sel = trace_buf[2567:2536];
		7'd80:  trace_entry_sel = trace_buf[2599:2568];
		7'd81:  trace_entry_sel = trace_buf[2631:2600];
		7'd82:  trace_entry_sel = trace_buf[2663:2632];
		7'd83:  trace_entry_sel = trace_buf[2695:2664];
		7'd84:  trace_entry_sel = trace_buf[2727:2696];
		7'd85:  trace_entry_sel = trace_buf[2759:2728];
		7'd86:  trace_entry_sel = trace_buf[2791:2760];
		7'd87:  trace_entry_sel = trace_buf[2823:2792];
		7'd88:  trace_entry_sel = trace_buf[2855:2824];
		7'd89:  trace_entry_sel = trace_buf[2887:2856];
		7'd90:  trace_entry_sel = trace_buf[2919:2888];
		7'd91:  trace_entry_sel = trace_buf[2951:2920];
		7'd92:  trace_entry_sel = trace_buf[2983:2952];
		7'd93:  trace_entry_sel = trace_buf[3015:2984];
		7'd94:  trace_entry_sel = trace_buf[3047:3016];
		7'd95:  trace_entry_sel = trace_buf[3079:3048];
		7'd96:  trace_entry_sel = trace_buf[3111:3080];
		7'd97:  trace_entry_sel = trace_buf[3143:3112];
		7'd98:  trace_entry_sel = trace_buf[3175:3144];
		7'd99:  trace_entry_sel = trace_buf[3207:3176];
		7'd100: trace_entry_sel = trace_buf[3239:3208];
		7'd101: trace_entry_sel = trace_buf[3271:3240];
		7'd102: trace_entry_sel = trace_buf[3303:3272];
		7'd103: trace_entry_sel = trace_buf[3335:3304];
		7'd104: trace_entry_sel = trace_buf[3367:3336];
		7'd105: trace_entry_sel = trace_buf[3399:3368];
		7'd106: trace_entry_sel = trace_buf[3431:3400];
		7'd107: trace_entry_sel = trace_buf[3463:3432];
		7'd108: trace_entry_sel = trace_buf[3495:3464];
		7'd109: trace_entry_sel = trace_buf[3527:3496];
		7'd110: trace_entry_sel = trace_buf[3559:3528];
		7'd111: trace_entry_sel = trace_buf[3591:3560];
		7'd112: trace_entry_sel = trace_buf[3623:3592];
		7'd113: trace_entry_sel = trace_buf[3655:3624];
		7'd114: trace_entry_sel = trace_buf[3687:3656];
		7'd115: trace_entry_sel = trace_buf[3719:3688];
		7'd116: trace_entry_sel = trace_buf[3751:3720];
		7'd117: trace_entry_sel = trace_buf[3783:3752];
		7'd118: trace_entry_sel = trace_buf[3815:3784];
		7'd119: trace_entry_sel = trace_buf[3847:3816];
		7'd120: trace_entry_sel = trace_buf[3879:3848];
		7'd121: trace_entry_sel = trace_buf[3911:3880];
		7'd122: trace_entry_sel = trace_buf[3943:3912];
		7'd123: trace_entry_sel = trace_buf[3975:3944];
		7'd124: trace_entry_sel = trace_buf[4007:3976];
		7'd125: trace_entry_sel = trace_buf[4039:4008];
		7'd126: trace_entry_sel = trace_buf[4071:4040];
		7'd127: trace_entry_sel = trace_buf[4103:4072];
		default: trace_entry_sel = 32'h0;
	endcase
end

// Parallel mux for the P byte appended after the main trace region.
// P bytes live at bits 4104..5127, one 8-bit entry per slot.
reg [7:0] trace_p_sel;
always @(*) begin
	case (trace_idx)
		7'd0:   trace_p_sel = trace_buf[4111:4104];
		7'd1:   trace_p_sel = trace_buf[4119:4112];
		7'd2:   trace_p_sel = trace_buf[4127:4120];
		7'd3:   trace_p_sel = trace_buf[4135:4128];
		7'd4:   trace_p_sel = trace_buf[4143:4136];
		7'd5:   trace_p_sel = trace_buf[4151:4144];
		7'd6:   trace_p_sel = trace_buf[4159:4152];
		7'd7:   trace_p_sel = trace_buf[4167:4160];
		7'd8:   trace_p_sel = trace_buf[4175:4168];
		7'd9:   trace_p_sel = trace_buf[4183:4176];
		7'd10:  trace_p_sel = trace_buf[4191:4184];
		7'd11:  trace_p_sel = trace_buf[4199:4192];
		7'd12:  trace_p_sel = trace_buf[4207:4200];
		7'd13:  trace_p_sel = trace_buf[4215:4208];
		7'd14:  trace_p_sel = trace_buf[4223:4216];
		7'd15:  trace_p_sel = trace_buf[4231:4224];
		7'd16:  trace_p_sel = trace_buf[4239:4232];
		7'd17:  trace_p_sel = trace_buf[4247:4240];
		7'd18:  trace_p_sel = trace_buf[4255:4248];
		7'd19:  trace_p_sel = trace_buf[4263:4256];
		7'd20:  trace_p_sel = trace_buf[4271:4264];
		7'd21:  trace_p_sel = trace_buf[4279:4272];
		7'd22:  trace_p_sel = trace_buf[4287:4280];
		7'd23:  trace_p_sel = trace_buf[4295:4288];
		7'd24:  trace_p_sel = trace_buf[4303:4296];
		7'd25:  trace_p_sel = trace_buf[4311:4304];
		7'd26:  trace_p_sel = trace_buf[4319:4312];
		7'd27:  trace_p_sel = trace_buf[4327:4320];
		7'd28:  trace_p_sel = trace_buf[4335:4328];
		7'd29:  trace_p_sel = trace_buf[4343:4336];
		7'd30:  trace_p_sel = trace_buf[4351:4344];
		7'd31:  trace_p_sel = trace_buf[4359:4352];
		7'd32:  trace_p_sel = trace_buf[4367:4360];
		7'd33:  trace_p_sel = trace_buf[4375:4368];
		7'd34:  trace_p_sel = trace_buf[4383:4376];
		7'd35:  trace_p_sel = trace_buf[4391:4384];
		7'd36:  trace_p_sel = trace_buf[4399:4392];
		7'd37:  trace_p_sel = trace_buf[4407:4400];
		7'd38:  trace_p_sel = trace_buf[4415:4408];
		7'd39:  trace_p_sel = trace_buf[4423:4416];
		7'd40:  trace_p_sel = trace_buf[4431:4424];
		7'd41:  trace_p_sel = trace_buf[4439:4432];
		7'd42:  trace_p_sel = trace_buf[4447:4440];
		7'd43:  trace_p_sel = trace_buf[4455:4448];
		7'd44:  trace_p_sel = trace_buf[4463:4456];
		7'd45:  trace_p_sel = trace_buf[4471:4464];
		7'd46:  trace_p_sel = trace_buf[4479:4472];
		7'd47:  trace_p_sel = trace_buf[4487:4480];
		7'd48:  trace_p_sel = trace_buf[4495:4488];
		7'd49:  trace_p_sel = trace_buf[4503:4496];
		7'd50:  trace_p_sel = trace_buf[4511:4504];
		7'd51:  trace_p_sel = trace_buf[4519:4512];
		7'd52:  trace_p_sel = trace_buf[4527:4520];
		7'd53:  trace_p_sel = trace_buf[4535:4528];
		7'd54:  trace_p_sel = trace_buf[4543:4536];
		7'd55:  trace_p_sel = trace_buf[4551:4544];
		7'd56:  trace_p_sel = trace_buf[4559:4552];
		7'd57:  trace_p_sel = trace_buf[4567:4560];
		7'd58:  trace_p_sel = trace_buf[4575:4568];
		7'd59:  trace_p_sel = trace_buf[4583:4576];
		7'd60:  trace_p_sel = trace_buf[4591:4584];
		7'd61:  trace_p_sel = trace_buf[4599:4592];
		7'd62:  trace_p_sel = trace_buf[4607:4600];
		7'd63:  trace_p_sel = trace_buf[4615:4608];
		7'd64:  trace_p_sel = trace_buf[4623:4616];
		7'd65:  trace_p_sel = trace_buf[4631:4624];
		7'd66:  trace_p_sel = trace_buf[4639:4632];
		7'd67:  trace_p_sel = trace_buf[4647:4640];
		7'd68:  trace_p_sel = trace_buf[4655:4648];
		7'd69:  trace_p_sel = trace_buf[4663:4656];
		7'd70:  trace_p_sel = trace_buf[4671:4664];
		7'd71:  trace_p_sel = trace_buf[4679:4672];
		7'd72:  trace_p_sel = trace_buf[4687:4680];
		7'd73:  trace_p_sel = trace_buf[4695:4688];
		7'd74:  trace_p_sel = trace_buf[4703:4696];
		7'd75:  trace_p_sel = trace_buf[4711:4704];
		7'd76:  trace_p_sel = trace_buf[4719:4712];
		7'd77:  trace_p_sel = trace_buf[4727:4720];
		7'd78:  trace_p_sel = trace_buf[4735:4728];
		7'd79:  trace_p_sel = trace_buf[4743:4736];
		7'd80:  trace_p_sel = trace_buf[4751:4744];
		7'd81:  trace_p_sel = trace_buf[4759:4752];
		7'd82:  trace_p_sel = trace_buf[4767:4760];
		7'd83:  trace_p_sel = trace_buf[4775:4768];
		7'd84:  trace_p_sel = trace_buf[4783:4776];
		7'd85:  trace_p_sel = trace_buf[4791:4784];
		7'd86:  trace_p_sel = trace_buf[4799:4792];
		7'd87:  trace_p_sel = trace_buf[4807:4800];
		7'd88:  trace_p_sel = trace_buf[4815:4808];
		7'd89:  trace_p_sel = trace_buf[4823:4816];
		7'd90:  trace_p_sel = trace_buf[4831:4824];
		7'd91:  trace_p_sel = trace_buf[4839:4832];
		7'd92:  trace_p_sel = trace_buf[4847:4840];
		7'd93:  trace_p_sel = trace_buf[4855:4848];
		7'd94:  trace_p_sel = trace_buf[4863:4856];
		7'd95:  trace_p_sel = trace_buf[4871:4864];
		7'd96:  trace_p_sel = trace_buf[4879:4872];
		7'd97:  trace_p_sel = trace_buf[4887:4880];
		7'd98:  trace_p_sel = trace_buf[4895:4888];
		7'd99:  trace_p_sel = trace_buf[4903:4896];
		7'd100: trace_p_sel = trace_buf[4911:4904];
		7'd101: trace_p_sel = trace_buf[4919:4912];
		7'd102: trace_p_sel = trace_buf[4927:4920];
		7'd103: trace_p_sel = trace_buf[4935:4928];
		7'd104: trace_p_sel = trace_buf[4943:4936];
		7'd105: trace_p_sel = trace_buf[4951:4944];
		7'd106: trace_p_sel = trace_buf[4959:4952];
		7'd107: trace_p_sel = trace_buf[4967:4960];
		7'd108: trace_p_sel = trace_buf[4975:4968];
		7'd109: trace_p_sel = trace_buf[4983:4976];
		7'd110: trace_p_sel = trace_buf[4991:4984];
		7'd111: trace_p_sel = trace_buf[4999:4992];
		7'd112: trace_p_sel = trace_buf[5007:5000];
		7'd113: trace_p_sel = trace_buf[5015:5008];
		7'd114: trace_p_sel = trace_buf[5023:5016];
		7'd115: trace_p_sel = trace_buf[5031:5024];
		7'd116: trace_p_sel = trace_buf[5039:5032];
		7'd117: trace_p_sel = trace_buf[5047:5040];
		7'd118: trace_p_sel = trace_buf[5055:5048];
		7'd119: trace_p_sel = trace_buf[5063:5056];
		7'd120: trace_p_sel = trace_buf[5071:5064];
		7'd121: trace_p_sel = trace_buf[5079:5072];
		7'd122: trace_p_sel = trace_buf[5087:5080];
		7'd123: trace_p_sel = trace_buf[5095:5088];
		7'd124: trace_p_sel = trace_buf[5103:5096];
		7'd125: trace_p_sel = trace_buf[5111:5104];
		7'd126: trace_p_sel = trace_buf[5119:5112];
		7'd127: trace_p_sel = trace_buf[5127:5120];
		default: trace_p_sel = 8'h0;
	endcase
end

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
		7'd63: line_char = " ";
		7'd64: line_char = "W";  // W:xxxx = last addr when PBR=$20
		7'd65: line_char = ":";
		7'd66: line_char = hex_char(lat_irq_vec[15:12]);
		7'd67: line_char = hex_char(lat_irq_vec[11:8]);
		7'd68: line_char = hex_char(lat_irq_vec[7:4]);
		7'd69: line_char = hex_char(lat_irq_vec[3:0]);
		7'd70: line_char = " ";
		7'd71: line_char = "L";
		7'd72: line_char = ":";
		7'd73: line_char = hex_char(lat_crash_bank[7:4]);
		7'd74: line_char = hex_char(lat_crash_bank[3:0]);
		7'd75: line_char = lat_vic_irq ? "!" : ".";
		7'd76: line_char = lat_frozen ? " " : 8'h0A;  // continue when frozen
		// Trace extension (only reached when lat_frozen=1)
		7'd77: line_char = "T";
		7'd78: line_char = "R";
		7'd79: line_char = ":";
		7'd80: line_char = hex_char({1'b0, lat_trace_idx[6:4]});
		7'd81: line_char = hex_char(lat_trace_idx[3:0]);
		7'd82: line_char = " ";
		7'd83: line_char = "P";
		7'd84: line_char = "C";
		7'd85: line_char = ":";
		7'd86: line_char = hex_char(lat_trace_entry[15:12]); // PC_hi[7:4]
		7'd87: line_char = hex_char(lat_trace_entry[11:8]);  // PC_hi[3:0]
		7'd88: line_char = hex_char(lat_trace_entry[7:4]);   // PC_lo[7:4]
		7'd89: line_char = hex_char(lat_trace_entry[3:0]);   // PC_lo[3:0]
		7'd90: line_char = " ";
		7'd91: line_char = "K";
		7'd92: line_char = ":";
		7'd93: line_char = hex_char(lat_trace_entry[23:20]); // PBR[7:4]
		7'd94: line_char = hex_char(lat_trace_entry[19:16]); // PBR[3:0]
		7'd95: line_char = " ";
		7'd96: line_char = "I";
		7'd97: line_char = ":";
		7'd98: line_char = hex_char(lat_trace_entry[31:28]); // IR[7:4]
		7'd99: line_char = hex_char(lat_trace_entry[27:24]); // IR[3:0]
		7'd100: line_char = " ";
		7'd101: line_char = "P";
		7'd102: line_char = ":";
		7'd103: line_char = hex_char(lat_trace_p[7:4]);
		7'd104: line_char = hex_char(lat_trace_p[3:0]);
		7'd105: line_char = 8'h0A;                           // newline
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
		trace_idx       <= 0;
		lat_frozen      <= 0;
		lat_trace_idx   <= 0;
		lat_trace_entry <= 0;
		lat_trace_p     <= 0;
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
			lat_irq_vec <= native_irq_vec;
			lat_crash_bank <= crash_bank;
			lat_vic_irq <= vic_irq;
			frame_cnt  <= frame_cnt + 1'b1;
			ch_cnt     <= 0;
			en_cnt     <= 0;
			cy_cnt     <= 0;

			// Latch frozen status and current trace entry for this frame.
			// trace_entry_sel is a combinational mux selected by trace_idx.
			lat_frozen      <= trace_buf[0];
			lat_trace_idx   <= trace_idx;
			lat_trace_entry <= trace_entry_sel;
			lat_trace_p     <= trace_p_sel;
			if (trace_buf[0])
				trace_idx <= trace_idx + 1'b1;

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
			if (char_idx == line_len_cur - 1'b1) begin
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
