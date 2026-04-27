//============================================================================
//  C64 Top level for MiSTer
//  Copyright (C) 2017-2021 Sorgelig
//
//  Used DE2-35 Top level by Dar (darfpga@aol.fr)
//
//  FPGA64 is Copyrighted 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
//  http://www.syntiac.com/fpga64.html
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

// ---------------------------------------------------------------------------
// Debug gating: modular compile-time categories. See
// docs/debug_infrastructure_modular_plan.md for rationale.
//
// Individual gates (define any subset from the QSF):
//   DBG_TRACE         -- 128-entry crash trace ring buffer + $DF20-$DFA0
//                        / $DFC9-$DFE8 read mux + bug_page view +
//                        BRK/0801 wipe triggers
//   DBG_UART          -- debug_uart_fmt formatter + UART_TXD override
//   DBG_OVERLAY       -- video debug overlay module
//   DBG_BUS_CAPTURE   -- CIA1/VIC/$0801/screen-write/SuperRAM-read capture
//                        processes + their diagnostic register mux reads
//
// Master toggle:
//   DEBUG_ENABLE  -- if defined (the default), implies all of the above.
//                    Release builds leave DEBUG_ENABLE AND all per-category
//                    macros undefined (equivalently, define DEBUG_RELEASE=1)
//                    so everything compiles out.
//
// IMPORTANT: DBG_TRACE and DBG_BUS_CAPTURE are also passed to
// fpga64_sid_iec as integer generics (see the instance parameter map
// later in this file). Half-gated (SV on, VHDL off) will dangle signal
// references. Keep the two sides in sync.
// ---------------------------------------------------------------------------
`ifndef DEBUG_ENABLE
  `ifndef DEBUG_RELEASE
    `define DEBUG_ENABLE 1
  `endif
`endif

`ifdef DEBUG_ENABLE
  `ifndef DBG_TRACE
    `define DBG_TRACE 1
  `endif
  `ifndef DBG_UART
    `define DBG_UART 1
  `endif
  `ifndef DBG_OVERLAY
    `define DBG_OVERLAY 1
  `endif
  `ifndef DBG_BUS_CAPTURE
    `define DBG_BUS_CAPTURE 1
  `endif
`endif

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign LED_DISK   = 0;
assign LED_POWER  = 0;
// LED debug probe: overrides normal LED when debug mode is active
assign LED_USER   = (dbg_led_mode == 2'd1) ? supercpu_emul :
                    (dbg_led_mode == 2'd2) ? dbg_cpu_en :
                    (dbg_led_mode == 2'd3) ? dbg_cpu_we :
                    (|drive_led | ioctl_download | ioctl_upload | ezfl_mod | tape_led | ~disk_ready);
assign BUTTONS    = 0;
assign VGA_DISABLE = 0;
assign VGA_SCALER = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Status Bit Map:
//              Upper                          Lower
// 0         1         2         3          4         5         6
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
//
// 6     7         8         9         10        11        12
// 45678901234567890123456789012345 67890123456789012345678901234567
// XXXXXXXXXXXXXXXXXX

`include "build_id.v"
localparam CONF_STR = {
	"C64;UART9600:2400;",
	"H7S0,D64G64T64D81,Mount #8;",
	"H0S1,D64G64T64D81,Mount #9;",
	"O[77:76],Mount Write Protected,Off,#8,#9,#8 & #9;",
	"-;",
	"F1,PRGCRTREUTAP;",
	"hAdBR[61],Save cartridge;",
	"hAO[62],Autosave,Off,On;",
	"h3-;",
	"h3R[7],Tape Play/Pause;",
	"h3R[23],Tape Unload;",
	"h3O[11],Tape Sound,Off,On;",
	"-;",

	"P1,Audio & Video;", 
 	"P1O[2],Video Standard,PAL,NTSC;",
	"P1O[35:34],VIC-II,656x,856x,Early 856x;",
	"P1O[5:4],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[10:8],Scandoubler Fx,None,HQ2x-320,HQ2x-160,CRT 25%,CRT 50%,CRT 75%;",
	"d1P1O[32],Vertical Crop,No,Yes;",
	"P1O[31:30],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[13],Left SID,6581,8580;",
	"P1O[16],Right SID,6581,8580;",
	"D4P1O[66:64],Left Filter,Default,Custom 1,Custom 2,Custom 3,Adjustable;",
	"D5P1O[69:67],Right Filter,Default,Custom 1,Custom 2,Custom 3,Adjustable;",
	"D4D8P1O[72:70],Left Fc Offset,0,1,2,3,4,5;",
	"D5D9P1O[75:73],Right Fc Offset,0,1,2,3,4,5;",
	"P1O[22:20],Right SID Port,Same,DE00,D420,D500,DF00;",
	"P1O[37],8580 Digifix,On,Off;",
	"P1FC7,FLT,Load Custom Filters;",
	"P1-;",
	"P1O[12],Sound Expander,Disabled,OPL2;",
	"P1O[41:40],DigiMax,Disabled,DE00,DF00;",
	"P1O[19:18],Stereo Mix,None,25%,50%,100%;",

	"P2,Hardware;", 
	"P2O[52],GeoRAM,Disabled,4MB;",
	"P2O[54:53],REU,Disabled,512KB,2MB (512KB wrap),16MB;",
	"P2-;",
	"P2O[25],External IEC,Disabled,Enabled;",
	"P2O[43],Expansion,Joysticks,RS232;",
	"P2O[51],RS232 mode,UP9600,VIC-1011;",
	"P2O[33],RS232 connection,Internal,External;",
	"P2O[36],Real-Time Clock,Auto,Disabled;",
	"P2O[45],CIA,6526,8521;",
	"P2-;",
	"P2O[27:26],Pot 1/2,Joy 1 Fire 2/3,Mouse,Paddles 1/2;",
	"P2O[29:28],Pot 3/4,Joy 2 Fire 2/3,Mouse,Paddles 3/4;",
	"P2-;",
	"P2O[60:59],Key modifier,L+R Shift,L Shift,R Shift;",
	"P2-;",
	"P2O[1],Release Keys on Reset,Yes,No;",
	"P2O[24],Clear RAM on Reset,Yes,No;",
	"P2O[50],Reset & Run PRG,Yes,No;",
	"P2O[42],Pause When OSD is Open,No,Yes;",
	"P2O[39],Tape Autoplay,Yes,No;",
	"P2O[38],Boot EasyFlash,Yes,No;",
	"P2-;",
	"P2FC8,ROM,System ROM C64+C1541 ;",
	"P2FC9,ROM,System ROM C1581     ;",
	"P2FC5,CRT,Boot Cartridge       ;",
	"P2-;",
	"P2O[15:14],System ROM,Loadable C64,Standard C64,C64GS,Japanese;",

	"P3,Drives;",
	"P3O[58:57],Enable Drive #8,If Mounted,Always,Never;",
	"P3O[56:55],Enable Drive #9,If Mounted,Always,Never;",
	"P3O[44],Parallel port,Enabled,Disabled;",
	"P3-;",
	"P3O[80:78],Drive RPM    (G64),300,301,302,305,310,295,298,299;",
	"P3O[81],Drive Wobble (G64),Off,On;",
	"P3-;",
	"P3R[6],Reset Disk Drives;",

	"-;",
	"O[3],Swap Joysticks,No,Yes;",
	"-;",
	"O[47:46],Turbo mode,Off,C128,Smart;",
	"d6O[49:48],Turbo speed,2x,3x,4x,1x (C64);",
	"O[89:88],SCPU Speed,20MHz (Max),4x,2x,1MHz;",
	"-;",
	"d1O[82],SuperCPU (65C816),Off,On;",
	"d1O[86],SCPU Kickstart ROM,Off,On;",
	"d1O[83],Debug Overlay,Off,On;",
	"O[85:84],LED Debug,Off,Emulation,CPU Active,CPU Write;",
	"d1O[87],Debug UART,Off,On;",
	"-;",
	"R[0],Reset;",
	"R[17],Reset & Detach Cartridge;",
	"J,Fire 1,Fire 2,Fire 3,Paddle Btn,Mod1,Mod2;",
	"jn,A,B,Y,X|P,R,L;",
	"jp,A,B,Y,X|P,R,L;",
	"V,v",`BUILD_DATE
};

wire pll_locked;
wire clk_sys;
wire clk64;
wire clk48;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk48),
	.outclk_1(clk64),
	.outclk_2(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(pll_locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

always @(posedge CLK_50M) begin
	reg ntscd = 0, ntscd2 = 0;
	reg [2:0] state = 0;
	reg ntsc_r;

	ntscd <= ntsc;
	ntscd2 <= ntscd;

	cfg_write <= 0;
	if(ntscd2 == ntscd && ntscd2 != ntsc_r) begin
		state <= 1;
		ntsc_r <= ntscd2;
	end

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
				/*
			3: begin
					cfg_address <= 4;
					cfg_data <= ntsc_r ? 'h20504 : 'h404;
					cfg_write <= 1;
				end
				*/
			5: begin
					cfg_address <= 7;
					cfg_data <= ntsc_r ? 3357876127 : 1503512573;
					cfg_write <= 1;
				end
			7: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

reg reset_n;
reg reset_wait = 0;
always @(posedge clk_sys) begin
	integer reset_counter;
	reg old_download;
	reg do_erase = 1;

	reset_n <= !reset_counter;
	old_download <= ioctl_download;

	if (RESET | status[0] | status[17] | buttons[1] | !pll_locked) begin
		if(RESET) do_erase <= 1;
		reset_counter <= 100000;
	end
	else if(~old_download & ioctl_download & load_prg & ~status[50]) begin
		// 2026-04-27: vanilla 6510 mode uses ~8μs (255 cycles) reset pulse
		// for PRG-load. The 65C816 needs a longer reset to fully clear
		// internal state — 255 cycles caused RAMTAS to re-loop at $FD6E-FD86
		// on the second boot (verified via UART F:0003-F:0016 stuck pattern).
		// Use 100000 cycles (~3ms) for SCPU mode to match cold-boot reset.
		do_erase <= 1;
		reset_wait <= 1;
		reset_counter <= supercpu_enable ? 100000 : 255;
	end
	else if (ioctl_download & (load_crt | load_rom)) begin
		do_erase <= 1;
		reset_counter <= 255;
	end
	else if ((ioctl_download || inj_meminit) & ~reset_wait);
	else if (erasing) force_erase <= 0;
	else if (!reset_counter) begin
		do_erase <= 0;
		// $FFCF (KERNAL CHRIN) — BASIC calls this to fetch first keyboard
		// byte at READY prompt. Fires AFTER cold-init NEW, AFTER READY
		// prints. Vanilla MGL auto-RUN works with this trigger; a prior
		// $A480 experiment broke Asterix (OOM under BASIC CLR).
		if(reset_wait && c64_addr == 'hFFCF) reset_wait <= 0;
	end
	else begin
		reset_counter <= reset_counter - 1;
		if (reset_counter == 100 && (~status[24] | do_erase)) force_erase <= 1;
	end
end

wire [15:0] joyA,joyB,joyC,joyD;
wire [15:0] joy = joyA | joyB | joyC | joyD;

wire [127:0] status;
wire        forced_scandoubler;

wire        ioctl_wr;
wire        ioctl_rd;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
wire        ioctl_download;
wire        ioctl_upload;
wire [31:0] ioctl_file_ext;

wire [31:0] sd_lba[2];
wire  [5:0] sd_blk_cnt[2];
wire  [1:0] sd_rd;
wire  [1:0] sd_wr;
wire  [1:0] sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[2];
wire        sd_buff_wr;
wire  [1:0] img_mounted;
wire [31:0] img_size;
wire        img_readonly;

wire [24:0] ps2_mouse;
wire [10:0] ps2_key;
wire  [1:0] buttons;
wire [21:0] gamma_bus;

wire  [7:0] pd1,pd2,pd3,pd4;

wire [64:0] RTC;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2), .BLKSZ(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joyA),
	.joystick_1(joyB),
	.joystick_2(joyC),
	.joystick_3(joyD),

	.paddle_0(pd1),
	.paddle_1(pd2),
	.paddle_2(pd3),
	.paddle_3(pd4),

	.status(status),
	.status_menumask({ezfl_mod || ezfl_save_en, cart_ezfl, ~status[69], ~status[66], status[58], |status[47:46], status[16], status[13], tap_loaded, 1'b0, |vcrop, status[56]}),
	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.RTC(RTC),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_file_ext(ioctl_file_ext),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_upload_req(ezfl_save),
	.ioctl_upload_index(ezfl_idx),
	.ioctl_upload(ioctl_upload),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),
	.ioctl_wait(ioctl_req_wr|ioctl_req_rd|reset_wait)
);

// PRG vs REU classification for MGL-pipe index=1 loads.
//
// Background: MGL `<file index="1">` entries arrive with `ioctl_index == 1`
// regardless of whether the file is a PRG or a .REU image. The only signal
// that differentiates them is the file extension carried in `ioctl_file_ext`.
//
// Problem observed 2026-04-18: during a MGL PRG load on the SuperCPU fork,
// `ioctl_file_ext` is ".REU" (stale or mid-update) AT the rising edge of
// `ioctl_download`. The wire `reu_by_ext` is thus 1 when bytes start
// arriving, so `load_prg` is 0 and `load_reu` is 0 (because ioctl_index
// lags slightly and reads as 0 for a few cycles too). PRG bytes get
// DROPPED on the floor → BASIC has no program → auto-RUN types R-U-N-Enter
// at an empty $0801 with no visible effect.
//
// Fix (v2, 2026-04-18): Latch the classification at the FIRST ioctl_wr
// pulse of the download. By the time the first data byte writes (hps_io
// FIO_FILE_TX_DAT), both FIO_FILE_INFO and FIO_FILE_INDEX have been
// transmitted and settled — the HPS protocol sequences INFO→INDEX→TX→DAT
// strictly. Default: treat as PRG (reu_by_ext=0) until proven .REU.
//
// Clearing: on the FALLING edge of ioctl_download we reset the latches so
// the next download starts fresh. We do NOT touch ioctl_file_ext itself
// (it lives in sys/hps_io and we must not modify sys/).
wire reu_by_ext_comb = (ioctl_file_ext == ".REU" || ioctl_file_ext == ".reu");
reg  reu_by_ext_latched = 1'b0;
reg  load_class_captured = 1'b0;  // '1' once we've captured the real class
reg  old_download_for_ext = 1'b0;
always @(posedge clk_sys) begin
    old_download_for_ext <= ioctl_download;
    // Capture at first ioctl_wr pulse of download — guaranteed after
    // FIO_FILE_INFO in the HPS protocol stream, so ioctl_file_ext is
    // definitively the current file's extension.
    if (ioctl_download && ioctl_wr && !load_class_captured) begin
        reu_by_ext_latched <= reu_by_ext_comb;
        load_class_captured <= 1'b1;
    end
    // Reset at the end of the download.
    if (old_download_for_ext & ~ioctl_download) begin
        load_class_captured <= 1'b0;
        reu_by_ext_latched <= 1'b0;
    end
end
wire reu_by_ext = reu_by_ext_latched;
// load_prg: valid during download once class is captured, or pre-capture
// default (assume PRG for index=1 so rising-edge reset/header handler work).
// Once class_captured, reu_by_ext is authoritative.
wire load_prg   = ioctl_index == 'h01 && !reu_by_ext;
wire load_crt   = ioctl_index == 'h41 || ioctl_index == 5;
wire load_reu   = ioctl_index == 'h81                          // F1 pos2 (OSD file browser)
               || (ioctl_index == 'h01 && reu_by_ext);         // MGL fallback
wire load_tap   = ioctl_index == 'hC1;
wire load_flt   = ioctl_index == 7;
wire load_rom   = ioctl_index == 8;
wire load_c1581 = ioctl_index == 9;

// Auto-run diagnostic counters (readable via $DF00 reg mux: $DFC0-$DFC7)
reg  [7:0] dbg_any_dl_cnt       = 0;   // any ioctl_download rising edge
reg  [7:0] dbg_idx_at_dl        = 0;   // ioctl_index value at rising edge
reg [15:0] dbg_ext_at_dl_hi     = 0;   // ioctl_file_ext[31:16] at rising edge
reg [15:0] dbg_ext_at_dl_lo     = 0;   // ioctl_file_ext[15:0]  at rising edge
reg  [7:0] dbg_classify_cnt     = 0;   // class capture fires
reg  [7:0] dbg_reu_by_ext_cap   = 0;   // {7'd0, reu_by_ext_comb at capture}
reg  [7:0] dbg_idx_at_capture   = 0;   // ioctl_index value at class capture
always @(posedge clk_sys) begin
    if (~old_download_for_ext & ioctl_download) begin
        dbg_any_dl_cnt   <= dbg_any_dl_cnt + 1'b1;
        dbg_idx_at_dl    <= ioctl_index[7:0];
        dbg_ext_at_dl_hi <= ioctl_file_ext[31:16];
        dbg_ext_at_dl_lo <= ioctl_file_ext[15:0];
    end
    if (ioctl_download && ioctl_wr && !load_class_captured) begin
        dbg_classify_cnt   <= dbg_classify_cnt + 1'b1;
        dbg_reu_by_ext_cap <= {7'd0, reu_by_ext_comb};
        dbg_idx_at_capture <= ioctl_index[7:0];
    end
end

wire game;
wire exrom;
wire io_rom;
wire cart_ce;
wire cart_we;
wire nmi;
wire cart_oe;
wire IOF_rd;
wire  [7:0] cart_data;
wire  [7:0] cart_wrdata;
wire [24:0] cart_addr;
wire cart_mem_req;

cartridge cartridge
(
	.clk32(clk_sys),
	.reset_n(reset_n),

	.cart_loading(ioctl_download && load_crt),
	.cart_id(cart_attached ? cart_id : status[52] ? 8'd99 : 8'd255),
	.cart_exrom(cart_exrom),
	.cart_game(cart_game),
	.cart_bank_laddr(cart_bank_laddr),
	.cart_bank_size(cart_bank_size),
	.cart_bank_num(cart_bank_num),
	.cart_bank_type(cart_bank_type),
	.cart_bank_raddr(ioctl_load_addr),
	.cart_bank_wr(cart_hdr_wr),
	.cart_boot(~status[38]),

	.exrom(exrom),
	.game(game),

	.romL(romL),
	.romH(romH),
	.UMAXromH(UMAXromH),
	.IOE(IOE),
	.IOF(IOF),
	.mem_write(ram_we),
	.mem_ce(ram_ce),
	.mem_ce_out(cart_ce),
	.mem_write_out(cart_we),
	.mem_in(sdram_data),
	.mem_out(cart_wrdata),
	.mem_addr(cart_addr),
	.mem_req(cart_mem_req),
	.mem_cycle(io_cycle),
	.IO_rom(io_rom),
	.IO_rd(cart_oe),
	.IO_data(cart_data),
	.addr_in(c64_addr),
	.data_in(c64_data_out),
	.data_out(c64_data_in),

	.freeze_key(freeze_key),
	.mod_key(mod_key),
	.nmi(nmi),
	.nmi_ack(nmi_ack)
);

wire ezfl_save = status[61] | (status[62] & OSD_STATUS & ezfl_mod);
reg  ezfl_mod = 0;
reg  ezfl_idx = 0;
reg  ezfl_save_en = 0;
always @(posedge clk_sys) begin
	reg save_old = 0;
	reg ext_old = 0;

	if(cart_mem_req) ezfl_mod <= 1;
	if(ioctl_download && load_crt) ezfl_mod <= 0;
	if(ioctl_upload) {ezfl_mod, ezfl_save_en} <= 0;
	
	save_old <= ezfl_save;
	if(~save_old & ezfl_save) ezfl_idx <= ~status[61];
	
	ext_old <= ext_crt;
	if(~ext_old & ext_crt) ezfl_save_en <= 1;
end

wire        dma_req;
wire        dma_cycle;
wire [15:0] dma_addr;
wire  [7:0] dma_dout;
wire  [7:0] dma_din;
wire        dma_we;
wire        ext_cycle;

wire [24:0] reu_ram_addr;
wire  [7:0] reu_ram_dout;
wire        reu_ram_we;
wire        reu_ram_active;  // '1' during STATE_PROC_RAM (REU SDRAM access phase)

wire  [7:0] reu_dout;
wire        reu_irq;

// REU SDRAM mux settling: delay reu_ram_active by 1 cycle to ensure the SDRAM
// addr/we/din mux has settled before cart_ce fires. Without this, the first
// cart_ce after reu_ram_active goes HIGH catches the mux transitioning, causing
// the SDRAM controller to capture old (non-REU) values at the CE rising edge.
// The "settled" signal requires reu_ram_active to be stable for at least 1 cycle.
reg reu_ram_active_d;
always @(posedge clk_sys) reu_ram_active_d <= reu_ram_active;
wire reu_ram_settled = reu_ram_active & reu_ram_active_d;

// REU SDRAM data: use sdram_data_reu (dedicated latch in sdram.v that captures
// the high byte only when a read completes for an address with bit[24]=1).
// This avoids two problems with capturing sdram_data directly:
// 1. bt (byte toggle) gets overwritten by io_cycle CEs with bit[24]=0
// 2. Delay-based capture races against CAS latency + intervening CEs
wire [7:0] sdram_data_reu;  // from sdram.dout_reu — stable REU read data

// (registered SDRAM mux removed — broke VIC timing. Using CE gating instead.)

// When SuperCPU is enabled, force REU to 16MB — SuperRAM shares the REU
// SDRAM region, and loader.prg uses REU DMA to copy game data.
// Without this, MGL loading resets the OSD status bits, leaving reu_cfg=0
// even though the .reu file data is in SDRAM.
wire  [1:0] reu_cfg = supercpu_enable ? 2'b11 : status[54:53];
// Bypass IOF (bus logic, -10ns timing violation) for reu_oe.
// Use c64_addr directly: during CPU phases, c64_addr = cpuAddr = $DFxx.
// During VIC phases (bad lines): c64_addr = vicAddr (not $DFxx), so reu_oe = 0.
wire        reu_oe  = (c64_addr[15:8] == 8'hDF) && (supercpu_bank == 8'h00) && (|reu_cfg);

// Register io_ext and io_data in clk_sys: breaks the timing-critical
// combinational path through io_ext → io_data_i → dataToCpu → cpuDi.
// 1-cycle delay is fine because the I/O address is stable for many cycles.
reg         io_ext_r;
reg   [7:0] io_data_r_sv;
always @(posedge clk_sys) begin
	io_ext_r    <= cart_oe | reu_oe | opl_en;
	// Use reu_reg_mux (direct register bypass) instead of reu_dout.
	// The REU's cpu_din (reu_dout) stays at $FF because the edge detection
	// on cpu_cs (IOF_raw) is unreliable due to timing violations.
	// The bypass mux reads registers directly via combinational outputs.
	if (cart_oe)
		io_data_r_sv <= cart_data;
	else if (opl_en)
		io_data_r_sv <= opl_dout;
	else
		io_data_r_sv <= reu_reg_mux;
end

reu reu
(
	.clk(clk_sys),
	.reset(~reset_n),
	.cfg(reu_cfg),

	.dma_req(dma_req),

	.dma_cycle(dma_cycle),
	.dma_addr(dma_addr),
	.dma_dout(dma_dout),
	.dma_din(dma_din),
	.dma_we(dma_we),

	// REU SDRAM access via cart_ce (fires at VIC0 and CPUC every rotation).
	// During reu_ram_active=1, the SDRAM addr mux routes through reu_ram_addr,
	// so all cart_ce pulses read/write from/to the REU address.
	// ram_din uses sdram_data_reu (dedicated latch in sdram.v) — captures high byte
	// only when SDRAM completes a read for addr with bit[24]=1 (REU region).
	// This avoids bt clobbering and capture timing races.
	.ram_cycle(cart_ce & dma_req),
	.ram_addr(reu_ram_addr),
	.ram_dout(reu_ram_dout),
	.ram_din(sdram_data_reu),
	.ram_we(reu_ram_we),
	.ram_active(reu_ram_active),

	// iof_fall_pulse is a 1-cycle pulse fired at the end of a $DFxx access.
	// By that cycle iof_*_latched hold the LAST observed values during
	// the access (for writes cpuWe=1 was captured). reu.v sees a clean
	// rising edge on cpu_cs with cpu_we = iof_we_latched settled to 1 for
	// writes or 0 for reads. Fires at most once per access so back-to-back
	// writes each get their own edge.
	.cpu_addr(iof_addr_latched),
	.cpu_dout(iof_dout_latched),
	.cpu_din(reu_dout),
	.cpu_we(iof_we_latched),
	.cpu_cs(iof_fall_pulse),

	.irq(reu_irq),

	// Direct register outputs for bypass read
	.reg_status(reu_reg_status),
	.reg_cmd(reu_reg_cmd),
	.reg_addr_c64(reu_reg_addr_c64),
	.reg_addr_ram(reu_reg_addr_ram),
	.reg_length(reu_reg_length),
	// CPU-written snapshot registers + command-fire diagnostics
	.reg_addr_c64_r(reu_reg_addr_c64_r),
	.reg_addr_ram_r(reu_reg_addr_ram_r),
	.reg_length_r(reu_reg_length_r),
	.reg_cmd_count(reu_reg_cmd_count),
	.reg_xfer_count(reu_reg_xfer_count),
	.reg_first_cmd(reu_reg_first_cmd),
	.reg_state(reu_reg_state),
	.reg_cs_edges(reu_reg_cs_edges),
	.reg_wr_attempts(reu_reg_wr_attempts),
	.reg_rd_attempts(reu_reg_rd_attempts),
	.reg_last_addr_lo(reu_reg_last_addr_lo),
	.reg_last_dout(reu_reg_last_dout)
);

// REU register bypass read: build mux from direct register outputs.
// The REU's internal edge detection (cpu_cs) is unreliable due to timing
// violations on the IOF_raw path. This mux provides register data directly.
wire [7:0] reu_reg_status;
wire [7:0] reu_reg_cmd;
wire [15:0] reu_reg_addr_c64;
wire [23:0] reu_reg_addr_ram;
wire [15:0] reu_reg_length;
// FETCH diagnostics (loader.prg debugging)
wire [15:0] reu_reg_addr_c64_r;
wire [23:0] reu_reg_addr_ram_r;
wire [15:0] reu_reg_length_r;
wire [15:0] reu_reg_cmd_count;
wire [15:0] reu_reg_xfer_count;
wire  [7:0] reu_reg_first_cmd;
wire  [1:0] reu_reg_state;
// Internal reu.v cs/we edge diagnostics (loader.prg debugging)
wire [15:0] reu_reg_cs_edges;
wire [15:0] reu_reg_wr_attempts;
wire [15:0] reu_reg_rd_attempts;
wire  [4:0] reu_reg_last_addr_lo;
wire  [7:0] reu_reg_last_dout;

// Read-side page select for the 128-entry crash trace ring buffer.
// CPU writes the desired page (0..3) to $DF1F. Writes to $DF1F pass
// through reu.v's falling-edge cs but $1F is outside reu.v's register
// range (0..10) so reu.v ignores it.
// DBG_TRACE=0 gates this entire paged-view block out. The mux cases that
// reference trace_entry_view / trace_p_view are also under DBG_TRACE, so
// no orphan references remain.
`ifdef DBG_TRACE
reg [1:0] bug_page;
initial bug_page = 2'b00;
always @(posedge clk_sys) begin
	if (dbg_cpu_we && dbg_cpu_addr == 16'hDF1F)
		bug_page <= dbg_cpu_data[1:0];
end

// Paged view of the 128-entry ring buffer: one 32-entry window at a time.
// Layout in dbg_bug_buf:
//   [7:0]       = status
//   [4103:8]    = 128 × 32 bits (PC_lo, PC_hi, PBR, IR) — entry k at bit 8+k*32
//   [5127:4104] = 128 × 8 bits P — entry k P at bit 4104+k*8
// Each page shows 32 contiguous entries: page p covers entries p*32..p*32+31.
reg [31:0] trace_entry_view [0:31];  // full 32-bit entry per slot
reg  [7:0] trace_p_view     [0:31];  // P byte per slot
integer ti;
always @(*) begin
	for (ti = 0; ti < 32; ti = ti + 1) begin
		case (bug_page)
			2'd0: begin
				trace_entry_view[ti] = dbg_bug_buf[8    + 0*1024 + ti*32 +: 32];
				trace_p_view[ti]     = dbg_bug_buf[4104 + 0*256  + ti*8  +: 8];
			end
			2'd1: begin
				trace_entry_view[ti] = dbg_bug_buf[8    + 1*1024 + ti*32 +: 32];
				trace_p_view[ti]     = dbg_bug_buf[4104 + 1*256  + ti*8  +: 8];
			end
			2'd2: begin
				trace_entry_view[ti] = dbg_bug_buf[8    + 2*1024 + ti*32 +: 32];
				trace_p_view[ti]     = dbg_bug_buf[4104 + 2*256  + ti*8  +: 8];
			end
			2'd3: begin
				trace_entry_view[ti] = dbg_bug_buf[8    + 3*1024 + ti*32 +: 32];
				trace_p_view[ti]     = dbg_bug_buf[4104 + 3*256  + ti*8  +: 8];
			end
		endcase
	end
end
`endif // DBG_TRACE

reg [7:0] reu_reg_mux;
always @(*) begin
	case (dbg_cpu_addr[7:0])
		0:  reu_reg_mux = reu_reg_status;
		1:  reu_reg_mux = reu_reg_cmd;
		2:  reu_reg_mux = reu_reg_addr_c64[7:0];
		3:  reu_reg_mux = reu_reg_addr_c64[15:8];
		4:  reu_reg_mux = reu_reg_addr_ram[7:0];
		5:  reu_reg_mux = reu_reg_addr_ram[15:8];
		6:  reu_reg_mux = reu_reg_addr_ram[23:16];
		7:  reu_reg_mux = reu_reg_length[7:0];
		8:  reu_reg_mux = reu_reg_length[15:8];
`ifdef DBG_BUS_CAPTURE
		// Diagnostic: ioctl transfer stats
		9:  reu_reg_mux = reu_ioctl_cnt[7:0];   // $DF09: ioctl byte count low
		10: reu_reg_mux = reu_ioctl_cnt[15:8];  // $DF0A: ioctl byte count mid
		11: reu_reg_mux = reu_ioctl_cnt[23:16]; // $DF0B: ioctl byte count high
		12: reu_reg_mux = reu_ioctl_idx;         // $DF0C: ioctl_index at start
		// Diagnostic: last ioctl write address
		13: reu_reg_mux = reu_ioctl_last_addr[7:0];   // $DF0D: last ioctl addr low
		14: reu_reg_mux = reu_ioctl_last_addr[15:8];  // $DF0E: last ioctl addr mid
		15: reu_reg_mux = reu_ioctl_last_addr[23:16]; // $DF0F: last ioctl addr high
		16: reu_reg_mux = {7'b0, reu_ioctl_last_addr[24]}; // $DF10: last ioctl addr bit24
		17: reu_reg_mux = reu_ioctl_last_data;         // $DF11: last ioctl data byte
		18: reu_reg_mux = reu_ioctl_byte0_data;        // $DF12: first byte data
		// Diagnostic: SDRAM write presentation (io_cycle→SDRAM)
		19: reu_reg_mux = dbg_iowr_count[7:0];        // $DF13: SDRAM write count low
		20: reu_reg_mux = dbg_iowr_count[15:8];       // $DF14: SDRAM write count mid
		21: reu_reg_mux = dbg_iowr_count[23:16];      // $DF15: SDRAM write count high
		22: reu_reg_mux = dbg_iowr_first_addr[7:0];   // $DF16: first SDRAM write addr low
		23: reu_reg_mux = dbg_iowr_first_addr[15:8];  // $DF17: first SDRAM write addr mid
		24: reu_reg_mux = dbg_iowr_first_addr[23:16]; // $DF18: first SDRAM write addr high
		25: reu_reg_mux = {7'b0, dbg_iowr_first_addr[24]}; // $DF19: first write addr bit24
		26: reu_reg_mux = dbg_iowr_first_data;        // $DF1A: first SDRAM write data
		// Diagnostic: SDRAM readback after REU upload
		27: reu_reg_mux = reu_rb_data;                 // $DF1B: readback byte 0 from REU_ADDR
		28: reu_reg_mux = {5'b0, reu_rb_done, reu_rb_active, reu_rb_pending}; // $DF1C: status
		29: reu_reg_mux = peek_addr[7:0];   // $DF1D: peek_addr lo (was dbg_wr_pending)
		30: reu_reg_mux = peek_addr[15:8];  // $DF1E: peek_addr mid (was dbg_bi_seen/bankhi)
		31: reu_reg_mux = peek_addr[23:16]; // $DF1F: peek_addr hi  (was dbg_iowr_bankhi_val)
		// Crash trace ring buffer (expanded to 128 entries, 2026-04-13)
		// $DF20: status = {wp[6:0], frozen}
		// $DF21..$DFA0: 32 entries × 4 bytes = (PC_lo, PC_hi, PBR, IR) each
		//   (current page, select page via write to $DF1F)
		// $DFC9..$DFE8: 32 P bytes for the current page
		// 128 entries total → 4 pages. Write 0/1/2/3 to $DF1F to pick.
`endif // DBG_BUS_CAPTURE
`ifdef DBG_TRACE
		32: reu_reg_mux = dbg_bug_buf[7:0];  // $DF20 status
		// Entry  0: $DF21..$DF24
		33:  reu_reg_mux = trace_entry_view[ 0][ 7: 0];
		34:  reu_reg_mux = trace_entry_view[ 0][15: 8];
		35:  reu_reg_mux = trace_entry_view[ 0][23:16];
		36:  reu_reg_mux = trace_entry_view[ 0][31:24];
		37:  reu_reg_mux = trace_entry_view[ 1][ 7: 0];
		38:  reu_reg_mux = trace_entry_view[ 1][15: 8];
		39:  reu_reg_mux = trace_entry_view[ 1][23:16];
		40:  reu_reg_mux = trace_entry_view[ 1][31:24];
		41:  reu_reg_mux = trace_entry_view[ 2][ 7: 0];
		42:  reu_reg_mux = trace_entry_view[ 2][15: 8];
		43:  reu_reg_mux = trace_entry_view[ 2][23:16];
		44:  reu_reg_mux = trace_entry_view[ 2][31:24];
		45:  reu_reg_mux = trace_entry_view[ 3][ 7: 0];
		46:  reu_reg_mux = trace_entry_view[ 3][15: 8];
		47:  reu_reg_mux = trace_entry_view[ 3][23:16];
		48:  reu_reg_mux = trace_entry_view[ 3][31:24];
		49:  reu_reg_mux = trace_entry_view[ 4][ 7: 0];
		50:  reu_reg_mux = trace_entry_view[ 4][15: 8];
		51:  reu_reg_mux = trace_entry_view[ 4][23:16];
		52:  reu_reg_mux = trace_entry_view[ 4][31:24];
		53:  reu_reg_mux = trace_entry_view[ 5][ 7: 0];
		54:  reu_reg_mux = trace_entry_view[ 5][15: 8];
		55:  reu_reg_mux = trace_entry_view[ 5][23:16];
		56:  reu_reg_mux = trace_entry_view[ 5][31:24];
		57:  reu_reg_mux = trace_entry_view[ 6][ 7: 0];
		58:  reu_reg_mux = trace_entry_view[ 6][15: 8];
		59:  reu_reg_mux = trace_entry_view[ 6][23:16];
		60:  reu_reg_mux = trace_entry_view[ 6][31:24];
		61:  reu_reg_mux = trace_entry_view[ 7][ 7: 0];
		62:  reu_reg_mux = trace_entry_view[ 7][15: 8];
		63:  reu_reg_mux = trace_entry_view[ 7][23:16];
		64:  reu_reg_mux = trace_entry_view[ 7][31:24];
		65:  reu_reg_mux = trace_entry_view[ 8][ 7: 0];
		66:  reu_reg_mux = trace_entry_view[ 8][15: 8];
		67:  reu_reg_mux = trace_entry_view[ 8][23:16];
		68:  reu_reg_mux = trace_entry_view[ 8][31:24];
		69:  reu_reg_mux = trace_entry_view[ 9][ 7: 0];
		70:  reu_reg_mux = trace_entry_view[ 9][15: 8];
		71:  reu_reg_mux = trace_entry_view[ 9][23:16];
		72:  reu_reg_mux = trace_entry_view[ 9][31:24];
		73:  reu_reg_mux = trace_entry_view[10][ 7: 0];
		74:  reu_reg_mux = trace_entry_view[10][15: 8];
		75:  reu_reg_mux = trace_entry_view[10][23:16];
		76:  reu_reg_mux = trace_entry_view[10][31:24];
		77:  reu_reg_mux = trace_entry_view[11][ 7: 0];
		78:  reu_reg_mux = trace_entry_view[11][15: 8];
		79:  reu_reg_mux = trace_entry_view[11][23:16];
		80:  reu_reg_mux = trace_entry_view[11][31:24];
		81:  reu_reg_mux = trace_entry_view[12][ 7: 0];
		82:  reu_reg_mux = trace_entry_view[12][15: 8];
		83:  reu_reg_mux = trace_entry_view[12][23:16];
		84:  reu_reg_mux = trace_entry_view[12][31:24];
		85:  reu_reg_mux = trace_entry_view[13][ 7: 0];
		86:  reu_reg_mux = trace_entry_view[13][15: 8];
		87:  reu_reg_mux = trace_entry_view[13][23:16];
		88:  reu_reg_mux = trace_entry_view[13][31:24];
		89:  reu_reg_mux = trace_entry_view[14][ 7: 0];
		90:  reu_reg_mux = trace_entry_view[14][15: 8];
		91:  reu_reg_mux = trace_entry_view[14][23:16];
		92:  reu_reg_mux = trace_entry_view[14][31:24];
		93:  reu_reg_mux = trace_entry_view[15][ 7: 0];
		94:  reu_reg_mux = trace_entry_view[15][15: 8];
		95:  reu_reg_mux = trace_entry_view[15][23:16];
		96:  reu_reg_mux = trace_entry_view[15][31:24];
		97:  reu_reg_mux = trace_entry_view[16][ 7: 0];
		98:  reu_reg_mux = trace_entry_view[16][15: 8];
		99:  reu_reg_mux = trace_entry_view[16][23:16];
		100: reu_reg_mux = trace_entry_view[16][31:24];
		101: reu_reg_mux = trace_entry_view[17][ 7: 0];
		102: reu_reg_mux = trace_entry_view[17][15: 8];
		103: reu_reg_mux = trace_entry_view[17][23:16];
		104: reu_reg_mux = trace_entry_view[17][31:24];
		105: reu_reg_mux = trace_entry_view[18][ 7: 0];
		106: reu_reg_mux = trace_entry_view[18][15: 8];
		107: reu_reg_mux = trace_entry_view[18][23:16];
		108: reu_reg_mux = trace_entry_view[18][31:24];
		109: reu_reg_mux = trace_entry_view[19][ 7: 0];
		110: reu_reg_mux = trace_entry_view[19][15: 8];
		111: reu_reg_mux = trace_entry_view[19][23:16];
		112: reu_reg_mux = trace_entry_view[19][31:24];
		113: reu_reg_mux = trace_entry_view[20][ 7: 0];
		114: reu_reg_mux = trace_entry_view[20][15: 8];
		115: reu_reg_mux = trace_entry_view[20][23:16];
		116: reu_reg_mux = trace_entry_view[20][31:24];
		117: reu_reg_mux = trace_entry_view[21][ 7: 0];
		118: reu_reg_mux = trace_entry_view[21][15: 8];
		119: reu_reg_mux = trace_entry_view[21][23:16];
		120: reu_reg_mux = trace_entry_view[21][31:24];
		121: reu_reg_mux = trace_entry_view[22][ 7: 0];
		122: reu_reg_mux = trace_entry_view[22][15: 8];
		123: reu_reg_mux = trace_entry_view[22][23:16];
		124: reu_reg_mux = trace_entry_view[22][31:24];
		125: reu_reg_mux = trace_entry_view[23][ 7: 0];
		126: reu_reg_mux = trace_entry_view[23][15: 8];
		127: reu_reg_mux = trace_entry_view[23][23:16];
		128: reu_reg_mux = trace_entry_view[23][31:24];
		129: reu_reg_mux = trace_entry_view[24][ 7: 0];
		130: reu_reg_mux = trace_entry_view[24][15: 8];
		131: reu_reg_mux = trace_entry_view[24][23:16];
		132: reu_reg_mux = trace_entry_view[24][31:24];
		133: reu_reg_mux = trace_entry_view[25][ 7: 0];
		134: reu_reg_mux = trace_entry_view[25][15: 8];
		135: reu_reg_mux = trace_entry_view[25][23:16];
		136: reu_reg_mux = trace_entry_view[25][31:24];
		137: reu_reg_mux = trace_entry_view[26][ 7: 0];
		138: reu_reg_mux = trace_entry_view[26][15: 8];
		139: reu_reg_mux = trace_entry_view[26][23:16];
		140: reu_reg_mux = trace_entry_view[26][31:24];
		141: reu_reg_mux = trace_entry_view[27][ 7: 0];
		142: reu_reg_mux = trace_entry_view[27][15: 8];
		143: reu_reg_mux = trace_entry_view[27][23:16];
		144: reu_reg_mux = trace_entry_view[27][31:24];
		145: reu_reg_mux = trace_entry_view[28][ 7: 0];
		146: reu_reg_mux = trace_entry_view[28][15: 8];
		147: reu_reg_mux = trace_entry_view[28][23:16];
		148: reu_reg_mux = trace_entry_view[28][31:24];
		149: reu_reg_mux = trace_entry_view[29][ 7: 0];
		150: reu_reg_mux = trace_entry_view[29][15: 8];
		151: reu_reg_mux = trace_entry_view[29][23:16];
		152: reu_reg_mux = trace_entry_view[29][31:24];
		153: reu_reg_mux = trace_entry_view[30][ 7: 0];
		154: reu_reg_mux = trace_entry_view[30][15: 8];
		155: reu_reg_mux = trace_entry_view[30][23:16];
		156: reu_reg_mux = trace_entry_view[30][31:24];
		157: reu_reg_mux = trace_entry_view[31][ 7: 0];
		158: reu_reg_mux = trace_entry_view[31][15: 8];
		159: reu_reg_mux = trace_entry_view[31][23:16];
		160: reu_reg_mux = trace_entry_view[31][31:24];
`endif // DBG_TRACE
`ifdef DBG_BUS_CAPTURE
		// REU FETCH diagnostics (loader.prg debugging)
		161: reu_reg_mux = reu_reg_cmd_count[7:0];        // $DFA1
		162: reu_reg_mux = reu_reg_cmd_count[15:8];       // $DFA2
		163: reu_reg_mux = reu_reg_xfer_count[7:0];       // $DFA3
		164: reu_reg_mux = reu_reg_xfer_count[15:8];      // $DFA4
		165: reu_reg_mux = reu_reg_first_cmd;             // $DFA5
		166: reu_reg_mux = {6'b0, reu_reg_state};         // $DFA6: live FSM state
		// CPU-written snapshot (preserved across autonomous addr/length updates)
		167: reu_reg_mux = reu_reg_addr_c64_r[7:0];       // $DFA7
		168: reu_reg_mux = reu_reg_addr_c64_r[15:8];      // $DFA8
		169: reu_reg_mux = reu_reg_addr_ram_r[7:0];       // $DFA9
		170: reu_reg_mux = reu_reg_addr_ram_r[15:8];      // $DFAA
		171: reu_reg_mux = reu_reg_addr_ram_r[23:16];     // $DFAB
		172: reu_reg_mux = reu_reg_length_r[7:0];         // $DFAC
		173: reu_reg_mux = reu_reg_length_r[15:8];        // $DFAD
		// IOF-chain diagnostic counters (where do REU writes die?)
		174: reu_reg_mux = dbg_dfxx_cpu_cnt[7:0];         // $DFAE
		175: reu_reg_mux = dbg_dfxx_cpu_cnt[15:8];        // $DFAF
		176: reu_reg_mux = dbg_dfxx_we_cnt[7:0];          // $DFB0
		177: reu_reg_mux = dbg_dfxx_we_cnt[15:8];         // $DFB1
		178: reu_reg_mux = dbg_iof_det_cnt[7:0];          // $DFB2
		179: reu_reg_mux = dbg_iof_det_cnt[15:8];         // $DFB3
		180: reu_reg_mux = dbg_iof_raw_cnt[7:0];          // $DFB4
		181: reu_reg_mux = dbg_iof_raw_cnt[15:8];         // $DFB5
		182: reu_reg_mux = dbg_dfxx_last_we_lo;           // $DFB6
		183: reu_reg_mux = dbg_dfxx_last_we_data;         // $DFB7
		// Internal reu.v cs/we edge diagnostics
		184: reu_reg_mux = reu_reg_cs_edges[7:0];         // $DFB8
		185: reu_reg_mux = reu_reg_cs_edges[15:8];        // $DFB9
		186: reu_reg_mux = reu_reg_wr_attempts[7:0];      // $DFBA
		187: reu_reg_mux = reu_reg_wr_attempts[15:8];     // $DFBB
		188: reu_reg_mux = reu_reg_rd_attempts[7:0];      // $DFBC
		189: reu_reg_mux = reu_reg_rd_attempts[15:8];     // $DFBD
		190: reu_reg_mux = {3'b0, reu_reg_last_addr_lo};  // $DFBE
		191: reu_reg_mux = reu_reg_last_dout;             // $DFBF
		// Phase-alignment diagnostics
		192: reu_reg_mux = dbg_iof_we_coinc[7:0];         // $DFC0 iof_det & we lo
		193: reu_reg_mux = dbg_iof_we_coinc[15:8];        // $DFC1
		194: reu_reg_mux = dbg_iof_we_latched_hi_cnt[7:0]; // $DFC2 iof_we_r rising edges lo
		195: reu_reg_mux = dbg_iof_we_latched_hi_cnt[15:8];// $DFC3
		196: reu_reg_mux = dbg_iof_cs_we_overlap[7:0];    // $DFC4 IOF_raw & iof_we_r lo
		197: reu_reg_mux = dbg_iof_cs_we_overlap[15:8];   // $DFC5
		198: reu_reg_mux = dbg_iof_we_at_raw_rise_cnt[7:0];  // $DFC6 iof_we_latched=1 at cs rise
		199: reu_reg_mux = dbg_iof_we_at_raw_rise_cnt[15:8]; // $DFC7
		200: reu_reg_mux = {7'b0, dbg_iof_we_at_raw_rise};   // $DFC8 sticky last value
`endif // DBG_BUS_CAPTURE
`ifdef DBG_TRACE
		// Crash trace ring buffer -- P byte region for current page ($DFC9..$DFE8)
		201: reu_reg_mux = trace_p_view[ 0];  // $DFC9
		202: reu_reg_mux = trace_p_view[ 1];
		203: reu_reg_mux = trace_p_view[ 2];
		204: reu_reg_mux = trace_p_view[ 3];
		205: reu_reg_mux = trace_p_view[ 4];
		206: reu_reg_mux = trace_p_view[ 5];
		207: reu_reg_mux = trace_p_view[ 6];
		208: reu_reg_mux = trace_p_view[ 7];
		209: reu_reg_mux = trace_p_view[ 8];
		210: reu_reg_mux = trace_p_view[ 9];
		211: reu_reg_mux = trace_p_view[10];
		212: reu_reg_mux = trace_p_view[11];
		213: reu_reg_mux = trace_p_view[12];
		214: reu_reg_mux = trace_p_view[13];
		215: reu_reg_mux = trace_p_view[14];
		216: reu_reg_mux = trace_p_view[15];
		217: reu_reg_mux = trace_p_view[16];
		218: reu_reg_mux = trace_p_view[17];
		219: reu_reg_mux = trace_p_view[18];
		220: reu_reg_mux = trace_p_view[19];
		221: reu_reg_mux = trace_p_view[20];
		222: reu_reg_mux = trace_p_view[21];
		223: reu_reg_mux = trace_p_view[22];
		224: reu_reg_mux = trace_p_view[23];
		225: reu_reg_mux = trace_p_view[24];
		226: reu_reg_mux = trace_p_view[25];
		227: reu_reg_mux = trace_p_view[26];
		228: reu_reg_mux = trace_p_view[27];
		229: reu_reg_mux = trace_p_view[28];
		230: reu_reg_mux = trace_p_view[29];
		231: reu_reg_mux = trace_p_view[30];
		232: reu_reg_mux = trace_p_view[31];  // $DFE8
`endif // DBG_TRACE
`ifdef DBG_BUS_CAPTURE
		// SuperRAM read-path diagnostics (see fpga64_sid_iec.vhd dbg_srr_* latches)
		233: reu_reg_mux = dbg_srr_count[7:0];   // $DFE9 total SuperRAM reads lo
		234: reu_reg_mux = dbg_srr_count[15:8];  // $DFEA total SuperRAM reads hi
		235: reu_reg_mux = dbg_srr_data;         // $DFEB last sdram_superram byte
		236: reu_reg_mux = dbg_srr_addr_hi;      // $DFEC addr_hi_816 at last read
		237: reu_reg_mux = dbg_srr_cache_bank;   // $DFED cache_cpu_bank at last read
		238: reu_reg_mux = dbg_srr_addr_lo;      // $DFEE cpuAddr_pre[7:0]  at last read
		239: reu_reg_mux = dbg_srr_addr_mid;     // $DFEF cpuAddr_pre[15:8] at last read
		// PRG load diagnostics
		240: reu_reg_mux = dbg_prg_dl_cnt;        // $DFF0 PRG download starts (load_prg rising)
		241: reu_reg_mux = dbg_inj_rise_cnt;      // $DFF1 inj_meminit rising edges
		// Auto-RUN diagnostic set (added 2026-04-18 for MGL PRG auto-RUN debug)
		242: reu_reg_mux = dbg_cpu_wr_0801_pc_lo; // $DFF2 PC-near-first-$0801-write lo
		243: reu_reg_mux = dbg_cpu_wr_0801_pc_hi; // $DFF3 PC-near-first-$0801-write hi
		244: reu_reg_mux = dbg_classify_cnt;      // $DFF4 class capture firings
		245: reu_reg_mux = {7'd0, dbg_reu_by_ext_cap[0]}; // $DFF5 reu_by_ext_comb captured value
		246: reu_reg_mux = prg_link_lo;           // $DFF6 PRG header byte 2 (link lo, captured at ioctl_addr==2)
		247: reu_reg_mux = prg_link_hi;           // $DFF7 PRG header byte 3 (link hi, captured at ioctl_addr==3)
		// Per-PRG download trace (resets on PRG download rising edge)
		248: reu_reg_mux = dbg_req_set_cnt[7:0];  // $DFF8 req_set_cnt lo
		249: reu_reg_mux = dbg_req_set_cnt[15:8]; // $DFF9 req_set_cnt hi
		250: reu_reg_mux = dbg_req_cons_cnt[7:0]; // $DFFA req_cons_cnt lo
		251: reu_reg_mux = dbg_req_cons_cnt[15:8];// $DFFB req_cons_cnt hi
		252: reu_reg_mux = dbg_cpu_wr_0801_cnt;   // $DFFC CPU writes to $0801 post-download (BASIC NEW?)
		253: reu_reg_mux = dbg_cpu_wr_0801_data;  // $DFFD last byte CPU wrote to $0801
		254: reu_reg_mux = dbg_inj_fall_cnt;      // $DFFE inj_meminit falling edges
		255: reu_reg_mux = dbg_strk_cnt;          // $DFFF start_strk pulses (RUN-type-ahead fires)
`endif // DBG_BUS_CAPTURE
		default: reu_reg_mux = 8'hFF;
	endcase
end

// rearrange joystick contacts for c64
wire [6:0] joyA_int = joy[8] ? 7'd0 : {joyA[6:4], joyA[0], joyA[1], joyA[2], joyA[3]};
wire [6:0] joyB_int = joy[8] ? 7'd0 : {joyB[6:4], joyB[0], joyB[1], joyB[2], joyB[3]};
wire [6:0] joyC_c64 = joy[8] ? 7'd0 : {joyC[6:4], joyC[0], joyC[1], joyC[2], joyC[3]};
wire [6:0] joyD_c64 = joy[8] ? 7'd0 : {joyD[6:4], joyD[0], joyD[1], joyD[2], joyD[3]};

// swap joysticks if requested
wire [6:0] joyA_c64 = status[3] ? joyB_int : joyA_int;
wire [6:0] joyB_c64 = status[3] ? joyA_int : joyB_int;

wire [7:0] paddle_1 = status[3] ? pd3 : pd1;
wire [7:0] paddle_2 = status[3] ? pd4 : pd2;
wire [7:0] paddle_3 = status[3] ? pd1 : pd3;
wire [7:0] paddle_4 = status[3] ? pd2 : pd4;

wire       paddle_1_btn = ~joy[8] & (status[3] ? joyC[7] : joyA[7]);
wire       paddle_2_btn = ~joy[8] & (status[3] ? joyD[7] : joyB[7]);
wire       paddle_3_btn = ~joy[8] & (status[3] ? joyA[7] : joyC[7]);
wire       paddle_4_btn = ~joy[8] & (status[3] ? joyB[7] : joyD[7]);

wire [1:0] pd12_mode = status[27:26];
wire [1:0] pd34_mode = status[29:28];

reg [24:0] ioctl_load_addr;
reg        ioctl_req_wr;
reg        ioctl_req_rd;

reg [15:0] cart_id;
reg [15:0] cart_bank_laddr;
reg [15:0] cart_bank_size;
reg [15:0] cart_bank_num;
reg  [7:0] cart_bank_type;
reg  [7:0] cart_exrom;
reg  [7:0] cart_game;
reg        cart_attached = 0;
reg  [3:0] cart_hdr_cnt;
reg        cart_hdr_wr;
reg [31:0] cart_blk_len;

reg        force_erase;
reg        erasing;

reg        inj_meminit = 0;
// Armed on PRG download falling edge; inj_meminit fires once reset_wait
// has also cleared ($A474 = post-BASIC-cold-NEW). Decouples the meminit
// trigger from the ioctl edge so HPS-side streaming quirks (wait-ignore)
// can't leave inj_meminit firing during BASIC boot and getting clobbered.
reg        inj_pending = 0;

// Captured PRG link bytes (first 2 data bytes → $0801/$0802), written back
// during inj_meminit to survive any BASIC NEW that ran during the download.
reg  [7:0] prg_link_lo = 0;
reg  [7:0] prg_link_hi = 0;

// PRG load diagnostic counters (accessible via $DFF0-$DFF7)
reg  [7:0] dbg_prg_dl_cnt = 0;        // PRG downloads started (ioctl_download rising + load_prg)
reg  [7:0] dbg_inj_rise_cnt = 0;      // inj_meminit 0→1 edges
reg  [7:0] dbg_inj_fall_cnt = 0;      // inj_meminit 1→0 edges
reg  [7:0] dbg_strk_cnt = 0;          // start_strk pulses
reg  [7:0] dbg_inj_end_lo = 0;        // last inj_end low byte
reg  [7:0] dbg_inj_end_hi = 0;        // last inj_end high byte
reg  [7:0] dbg_last_ioctl_idx = 0;    // last ioctl_index on download start
reg  [7:0] dbg_last_load_flags = 0;   // {load_tap,load_rom,load_crt,load_reu,load_flt,load_prg,reu_by_ext,1'b0}
// Per-download trace: reset on PRG download rising edge, captures request/consume counts.
reg [15:0] dbg_req_set_cnt = 0;       // # times ioctl_wr path set ioctl_req_wr for this PRG
reg [15:0] dbg_req_cons_cnt = 0;      // # times io_cycle consumed a ioctl_req_wr for this PRG
reg  [7:0] dbg_wr1_addr_lo = 0;       // first consumed write: addr[7:0]
reg  [7:0] dbg_wr1_addr_hi = 0;       // first consumed write: addr[15:8]
reg  [7:0] dbg_wr1_data    = 0;       // first consumed write: data
reg  [7:0] dbg_wr2_addr_lo = 0;       // second consumed write
reg  [7:0] dbg_wr2_addr_hi = 0;
reg  [7:0] dbg_wr2_data    = 0;
// Sticky flags for specific addresses during a PRG download:
reg        dbg_hit_0800 = 0;  // any io_cycle write at addr 25'h000800 during PRG dl
reg        dbg_hit_0801 = 0;  // $000801
reg        dbg_hit_0802 = 0;  // $000802
reg  [7:0] dbg_0801_data = 0; // data written at $0801 (last)
reg  [7:0] dbg_0802_data = 0; // data written at $0802 (last)
// CPU-side write capture: any ram_we pulse at $0801 after ioctl_download drops.
// Fires during BASIC boot / RUN processing. If count > 0 after download end,
// the CPU is overwriting what io_cycle just wrote.
reg  [7:0] dbg_cpu_wr_0801_cnt = 0;
reg  [7:0] dbg_cpu_wr_0801_data = 0;  // last CPU-written byte at $0801
// PC snapshot at first post-meminit CPU write to $0801. Captures c64_addr
// from the previous clk32 cycle, which for typical 6510 STA abs is the
// operand-high fetch PC — close enough to identify the writing routine.
reg  [7:0] dbg_cpu_wr_0801_pc_lo = 0;
reg  [7:0] dbg_cpu_wr_0801_pc_hi = 0;
reg [15:0] prev_c64_addr = 0;
// inj_end — the post-download BASIC end-of-program address. Hoisted to
// module scope (was local to the ioctl always block) so Quartus infers a
// plain module-level FF — the local-reg variant was landing at $0803
// instead of the real ~$BC14 for Asterix, causing VARTAB/ARYTAB/etc.
// to be set to empty-program values.
reg [15:0] inj_end = 0;

// RELINK retry mechanism — after the initial inj_meminit walk ends and
// start_strk fires to type "RUN<ENTER>", BASIC's cold-init NEW ($A644)
// already wiped $0801/$0802 back to zero, and observation shows *further*
// CPU writes of zero land there before the typed RUN makes BASIC read
// the link bytes. To race those writes we re-fire the walk's last two
// writes ($0801=prg_link_lo, $0802=prg_link_hi) a bunch of times over
// the next ~160 ms, via mini-walks that start at ioctl_load_addr=$801
// and terminate the usual way at $803. start_strk is gated so it only
// pulses on the INITIAL walk's falling edge, not on relink walks.
reg  [5:0] relink_retry = 0;        // remaining mini-walks
reg [20:0] relink_wait  = 0;        // clk32 countdown between relinks
reg        is_relink_walk = 0;      // 1 while a mini-walk is in flight
reg        old_is_relink_walk = 0;  // registered for edge detection
reg        strk_fired_once = 0;     // gate: RUN-keystrokes fire ONCE per PRG dl

// Auto-RUN data-path override: for a few seconds after start_strk fires,
// force CPU reads of bank-$00 $0801/$0802 to return prg_link_lo/hi even
// if BASIC cold-init / NEW is still writing zeros there. Wins the race
// regardless of who's writing RAM. 3 s at clk_sys=32 MHz = 96M cycles.
reg [26:0] autorun_timer = 0;   // 27-bit, up to ~134M cycles (~4.2 s)
wire       autorun_override_active = |autorun_timer;

wire       io_cycle;
reg        io_cycle_ce;
reg        io_cycle_we;
reg [24:0] io_cycle_addr;
reg  [7:0] io_cycle_data;
// 1-cycle pulse to write-through an io_cycle bank-$00 byte to BRAM port A.
// Keeps BRAM coherent with SDRAM for ioctl PRG downloads (which bypass CPU).
reg        io_bram_we_pulse = 0;

localparam TAP_ADDR = 25'h0200000;
localparam REU_ADDR = 25'h1000000;
localparam CRT_ADDR = 25'h0100000;

wire cart_ezfl = cart_attached && (cart_id == 32 || cart_id ==33);
reg ext_crt = 0;

always @(posedge clk_sys) begin
	reg  [4:0] erase_to;
	reg        old_download;
	reg        erase_cram;
	reg        io_cycleD;
	reg        old_st0 = 0;
	reg        old_meminit;
	reg  [7:0] inj_meminit_data;
	reg  [2:0] rd_cyc;
	reg        ioctl_rd_en;

	old_download <= ioctl_download;
	io_cycleD <= io_cycle;
	cart_hdr_wr <= 0;

	// REU readback: trigger when REU download ends
	if (old_download && !ioctl_download && load_reu) begin
		reu_rb_pending <= 1;
		reu_rb_done <= 0;
		reu_rb_data <= 8'hEE;
		reu_rb_addr <= REU_ADDR + 25'h20000;  // bank $02:$0000
	end
	// v69: PRG readback — arm AFTER inj_meminit completes, not at download-fall.
	// inj_meminit walks ZP addresses 0..$FF via repeated ioctl_req_wr=1 pulses,
	// which blocks the reu_rb_pending service branch (gated on !ioctl_req_wr).
	// Arming on inj_meminit's FALLING edge guarantees ioctl_req_wr is stable 0.
	// Latch prg_dl_seen during download; at inj_meminit fall, arm readback.
	if (ioctl_download && load_prg) prg_dl_seen <= 1;
	old_inj_meminit_rb <= inj_meminit;
	if (old_inj_meminit_rb & ~inj_meminit & prg_dl_seen) begin
		reu_rb_pending <= 1;
		reu_rb_done <= 0;
		reu_rb_data <= 8'hEE;
		reu_rb_addr <= 25'h0008B94;  // asterix.prg byte at phase-1 pass-52 src
		prg_dl_seen <= 0;
		dbg_prg_rb_arm_cnt <= dbg_prg_rb_arm_cnt + 1'b1;
	end

	// POKE-triggered SDRAM peek register (replaces dbg_wr SDRAM-write-test).
	// $DF1D/$DF1E/$DF1F latch the 24-bit peek address; $DF1F write also
	// triggers an SDRAM readback into reu_rb_data ($DF1B) and arms
	// auto-rearm (so the byte refreshes every io_cycle slot until reset).
	if (IOF_raw && dbg_cpu_we && dbg_cpu_addr[7:0] == 8'h1D) begin
		peek_addr[7:0] <= c64_data_out;
	end
	if (IOF_raw && dbg_cpu_we && dbg_cpu_addr[7:0] == 8'h1E) begin
		peek_addr[15:8] <= c64_data_out;
	end
	if (IOF_raw && dbg_cpu_we && dbg_cpu_addr[7:0] == 8'h1F) begin
		peek_addr[23:16] <= c64_data_out;
		// Arm SDRAM readback: bit24=0 for bank $00, bit24=1 for bank $01+
		reu_rb_pending <= 1;
		reu_rb_done <= 0;
		reu_rb_addr <= {(c64_data_out != 8'h00), c64_data_out, peek_addr[15:0]};
		peek_armed <= 1'b1;
	end
	// v71: SDRAM readback capture — widened shift register 3→8 bits.
	// v70 showed capture firing but sdram_data = $EE (unchanged). Root cause:
	// CAS-2 read needs 5 clk_sys from ce rising to dout_r update; old [2] fires
	// at 3 clk_sys (too early). Capture at [7] gives 8 clk_sys, safe margin.
	reu_rb_cyc <= {reu_rb_cyc[6:0], io_cycle & reu_rb_active};
	if (reu_rb_cyc[7] && !reu_rb_done) begin
		reu_rb_data <= sdram_data;
		reu_rb_done <= 1;
		reu_rb_active <= 0;
		dbg_prg_rb_cap_cnt <= dbg_prg_rb_cap_cnt + 1'b1;  // v70: capture diagnostic
		// Peek auto-rearm: once armed by $DF1F write, keep refreshing the
		// byte at peek_addr indefinitely (so UART W: shows live contents).
		if (peek_armed) begin
			peek_data <= sdram_data;
			peek_seq  <= peek_seq + 1'b1;
			reu_rb_pending <= 1;
			reu_rb_done <= 0;
			reu_rb_addr <= {(peek_addr[23:16] != 8'h00), peek_addr[23:0]};
		end
	end
	
	io_bram_we_pulse <= 0;  // default: clear pulse each clock
	if (~io_cycle & io_cycleD) begin
		io_cycle_ce <= 1;
		io_cycle_we <= 0;
		io_cycle_addr <= tap_play_addr + TAP_ADDR;
		if (ioctl_req_wr) begin
			ioctl_req_wr <= 0;
			io_cycle_we <= 1;
			io_cycle_addr <= ioctl_load_addr;
			ioctl_load_addr <= ioctl_load_addr + 1'b1;
			if (erasing) io_cycle_data <= {8{ioctl_load_addr[6]}};
			else if (inj_meminit) io_cycle_data <= inj_meminit_data;
			else io_cycle_data <= ioctl_data;
			// Bank $00 write-through to BRAM: fire a 1-cycle pulse so the
			// byte lands in BRAM alongside the SDRAM write.
			if (ioctl_load_addr[24:16] == 9'h000)
				io_bram_we_pulse <= 1;
			// Per-PRG diag: capture first 2 consumed writes + count
			if (ioctl_download && load_prg) begin
				dbg_req_cons_cnt <= dbg_req_cons_cnt + 1'b1;
				if (dbg_req_cons_cnt == 16'd0) begin
					dbg_wr1_addr_lo <= ioctl_load_addr[7:0];
					dbg_wr1_addr_hi <= ioctl_load_addr[15:8];
					dbg_wr1_data    <= (erasing) ? {8{ioctl_load_addr[6]}}
					                 : (inj_meminit ? inj_meminit_data : ioctl_data);
				end else if (dbg_req_cons_cnt == 16'd1) begin
					dbg_wr2_addr_lo <= ioctl_load_addr[7:0];
					dbg_wr2_addr_hi <= ioctl_load_addr[15:8];
					dbg_wr2_data    <= (erasing) ? {8{ioctl_load_addr[6]}}
					                 : (inj_meminit ? inj_meminit_data : ioctl_data);
				end
			end
			// Address-specific sticky flags: count ALL io_cycle writes (not gated)
			if (ioctl_load_addr[24:16] == 9'h000) begin
				if (ioctl_load_addr[15:0] == 16'h0800) dbg_hit_0800 <= 1;
				if (ioctl_load_addr[15:0] == 16'h0801) begin
					dbg_hit_0801  <= 1;
					dbg_0801_data <= (erasing) ? {8{ioctl_load_addr[6]}}
					               : (inj_meminit ? inj_meminit_data : ioctl_data);
				end
				if (ioctl_load_addr[15:0] == 16'h0802) begin
					dbg_hit_0802  <= 1;
					dbg_0802_data <= (erasing) ? {8{ioctl_load_addr[6]}}
					               : (inj_meminit ? inj_meminit_data : ioctl_data);
				end
			end
		end

		if(ioctl_req_rd) begin
			io_cycle_addr <= ioctl_load_addr;
			ioctl_rd_en <= 1;
		end

		// POKE-triggered SDRAM write test: write to REU SDRAM via io_cycle
		if (dbg_wr_pending && !ioctl_req_wr && !ioctl_req_rd && !reu_rb_pending) begin
			io_cycle_addr <= dbg_wr_addr;
			io_cycle_data <= dbg_wr_data;
			io_cycle_we <= 1;           // WRITE
			dbg_wr_pending <= 0;
			// Auto-trigger readback after write completes
			reu_rb_pending <= 1;
			reu_rb_done <= 0;
			reu_rb_data <= 8'hEE;
			reu_rb_addr <= dbg_wr_addr;  // read back what we just wrote
		end

		// SDRAM readback: schedule a read from bank $02:$0000 after write or REU download
		if (reu_rb_pending && !ioctl_req_wr && !ioctl_req_rd && !dbg_wr_pending) begin
			io_cycle_addr <= reu_rb_addr;  // generic readback target
			io_cycle_we <= 0;           // read, not write
			reu_rb_pending <= 0;
			reu_rb_active <= 1;
		end
	end
	
	if (io_cycle) {io_cycle_ce, io_cycle_we, ioctl_rd_en} <= 0;

	if (ioctl_rd) begin
		if(ioctl_addr == 0) ioctl_load_addr <= CRT_ADDR;
		ioctl_req_rd <= 1;
	end

	rd_cyc <= {rd_cyc[1:0], io_cycle & io_cycle_ce & ioctl_rd_en};
	if(rd_cyc[2]) begin
		ioctl_din <= sdram_data;
		ioctl_req_rd <= 0;
		ioctl_load_addr <= ioctl_load_addr + 1'b1;
	end


	if (ioctl_wr) begin
		if (load_prg) begin
			// PRG header
			// Load address low-byte
			if      (ioctl_addr == 0) begin ioctl_load_addr[7:0]  <= ioctl_data; inj_end[7:0]  <= ioctl_data; end
			// Load address high-byte
			else if (ioctl_addr == 1) begin ioctl_load_addr[15:8] <= ioctl_data; inj_end[15:8] <= ioctl_data; end
			else begin
				if (ioctl_addr == 2) prg_link_lo <= ioctl_data;
				if (ioctl_addr == 3) prg_link_hi <= ioctl_data;
				ioctl_req_wr <= 1;
				inj_end <= inj_end + 1'b1;
				dbg_req_set_cnt <= dbg_req_set_cnt + 1'b1;
			end
		end

		if (load_crt) begin
			if (ioctl_addr == 0) begin
				ioctl_load_addr <= CRT_ADDR;
				cart_blk_len <= 0;
				cart_hdr_cnt <= 0;
			end 

			if (ioctl_addr == 8'h16) cart_id[15:8]   <= ioctl_data;
			if (ioctl_addr == 8'h17) cart_id[7:0]    <= ioctl_data;
			if (ioctl_addr == 8'h18) cart_exrom[7:0] <= ioctl_data;
			if (ioctl_addr == 8'h19) cart_game[7:0]  <= ioctl_data;

			if (ioctl_addr >= 8'h40) begin
				if (cart_blk_len == 0 & cart_hdr_cnt == 0) begin
					cart_hdr_cnt <= 1;
					if (ioctl_load_addr[12:0] != 0) begin
						// align to 8KB boundary
						ioctl_load_addr[12:0] <= 0;
						ioctl_load_addr[24:13] <= ioctl_load_addr[24:13] + 1'b1;
					end
				end else if (cart_hdr_cnt != 0) begin
					cart_hdr_cnt <= cart_hdr_cnt + 1'b1;
					if (cart_hdr_cnt == 4)  cart_blk_len[31:24]  <= ioctl_data;
					if (cart_hdr_cnt == 5)  cart_blk_len[23:16]  <= ioctl_data;
					if (cart_hdr_cnt == 6)  cart_blk_len[15:8]   <= ioctl_data;
					if (cart_hdr_cnt == 7)  cart_blk_len[7:0]    <= ioctl_data;
					if (cart_hdr_cnt == 8)  cart_blk_len         <= cart_blk_len - 8'h10;
					if (cart_hdr_cnt == 9)  cart_bank_type       <= ioctl_data;
					if (cart_hdr_cnt == 10) cart_bank_num[15:8]  <= ioctl_data;
					if (cart_hdr_cnt == 11) cart_bank_num[7:0]   <= ioctl_data;
					if (cart_hdr_cnt == 12) cart_bank_laddr[15:8]<= ioctl_data;
					if (cart_hdr_cnt == 13) cart_bank_laddr[7:0] <= ioctl_data;
					if (cart_hdr_cnt == 14) cart_bank_size[15:8] <= ioctl_data;
					if (cart_hdr_cnt == 15) cart_bank_size[7:0]  <= ioctl_data;
					if (cart_hdr_cnt == 15) cart_hdr_wr <= 1;
				end
				else begin
					cart_blk_len <= cart_blk_len - 1'b1;
					ioctl_req_wr <= 1;
				end
			end
		end
		
		if (load_tap) begin
			if (ioctl_addr == 0)  ioctl_load_addr <= TAP_ADDR;
			if (ioctl_addr == 12) tap_version <= ioctl_data[1:0];
			ioctl_req_wr <= 1;
		end

		if (load_reu) begin
			if (ioctl_addr == 0) ioctl_load_addr <= REU_ADDR;
			ioctl_req_wr <= 1;
			reu_ioctl_cnt <= reu_ioctl_cnt + 1'd1;
		end
	end
	
	if (old_download != ioctl_download && load_crt) begin
		cart_attached <= old_download;
		erase_cram <= 1;
		ext_crt <= ioctl_download && (ioctl_file_ext == ".CRT");
	end 

	// PRG load diagnostics: capture load flags + ioctl_index on any download start
	if (~old_download & ioctl_download) begin
		dbg_last_ioctl_idx <= ioctl_index;
		dbg_last_load_flags <= {load_tap, load_rom, load_crt, load_reu, load_flt, load_prg, reu_by_ext, 1'b0};
		if (load_prg) begin
			dbg_prg_dl_cnt <= dbg_prg_dl_cnt + 1'b1;
			dbg_req_set_cnt  <= 0;
			dbg_req_cons_cnt <= 0;
			dbg_wr1_addr_lo  <= 0; dbg_wr1_addr_hi <= 0; dbg_wr1_data <= 0;
			dbg_wr2_addr_lo  <= 0; dbg_wr2_addr_hi <= 0; dbg_wr2_data <= 0;
			dbg_hit_0800 <= 0; dbg_hit_0801 <= 0; dbg_hit_0802 <= 0;
			dbg_0801_data <= 0; dbg_0802_data <= 0;
			dbg_cpu_wr_0801_cnt <= 0; dbg_cpu_wr_0801_data <= 0;
		end
	end

	// meminit for RAM injection — fire on FALLING edge of ioctl_download
	// only (commit 8ef779f). The verified-working fix: run zero-page BASIC
	// pointer init AFTER the PRG bytes have landed in SDRAM/BRAM, so that
	// inj_end has its real post-load value and BASIC sees a valid program.
	// Firing on rising edge (vanilla behavior) is wrong for SCPU because it
	// races the PRG header processing and leaves BASIC pointers pointing
	// at garbage.
	// HEAD-compatible immediate fire on download falling edge (no reset_wait
	// gate). Adding a !reset_wait gate races BASIC cold-init NEW on some
	// paths — vanilla's working flow fires meminit immediately once the
	// download bytes have landed, regardless of CHRIN/$FFCF timing.
	// HEAD behavior: fire inj_meminit immediately on PRG-download fall.
	// 2026-04-27 attempt to gate on !reset_wait broke KERNAL boot (CPU stuck
	// at $FF5F). Reverted. Relying on relink_retry below to re-fire walks
	// after BASIC NEW would otherwise wipe link bytes.
	if (old_download & ~ioctl_download && load_prg && !inj_meminit) begin
		inj_meminit <= 1;
		ioctl_load_addr <= 0;
		dbg_inj_rise_cnt <= dbg_inj_rise_cnt + 1'b1;
	end

	// RELINK: arm retry counter at INITIAL meminit end (not mini-walks),
	// then periodically fire mini-walks starting at $801 that re-write
	// $0801/$0802 = prg_link_lo/hi. old_is_relink_walk (registered below)
	// edge-detects initial-walk end vs mini-walk end correctly — by the
	// cycle after meminit falls, is_relink_walk has already been reset
	// to 0, so using it directly would re-arm on every mini-walk end too.
	old_is_relink_walk <= is_relink_walk;
	if (old_meminit & ~inj_meminit & ~old_is_relink_walk) begin
		relink_retry <= 6'd32;             // 2026-04-27: re-enabled for SCPU
		relink_wait  <= 21'd160_000;       // ~5ms gap before first relink

	end
	if (relink_retry > 0 && !inj_meminit && !ioctl_req_wr) begin
		if (relink_wait > 0)
			relink_wait <= relink_wait - 1'b1;
		else begin
			// Fire mini-walk: start at $801, walk hits $801/$802 cases
			// then terminates at $803. is_relink_walk tells start_strk
			// gate to NOT pulse again.
			inj_meminit    <= 1;
			ioctl_load_addr <= 'h801;
			is_relink_walk <= 1;
			relink_retry   <= relink_retry - 1'b1;
			relink_wait    <= 21'd160_000;
		end
	end

	if (inj_meminit) begin
		if (!ioctl_req_wr) begin
			// check if done with ZP walk (vanilla behavior: stop at $100)
			if (ioctl_load_addr == 'h100) begin
				inj_meminit    <= 0;
				is_relink_walk <= 0;
			end
			else begin
				ioctl_req_wr <= 1;

				// Initialize BASIC pointers to simulate the BASIC LOAD command
				case(ioctl_load_addr)
					// TXT (2B-2C)
					'h2B: inj_meminit_data <= 'h01;
					'h2C: inj_meminit_data <= 'h08;

					// SAVE_START (AC-AD)
					'hAC, 'hAD: inj_meminit_data <= 'h00;

					// VAR (2D-2E), ARY (2F-30), STR (31-32), LOAD_END (AE-AF)
					'h2D, 'h2F, 'h31, 'hAE: inj_meminit_data <= inj_end[7:0];
					'h2E, 'h30, 'h32, 'hAF: inj_meminit_data <= inj_end[15:8];

					default: begin
						ioctl_req_wr <= 0;
						// advance
						ioctl_load_addr <= ioctl_load_addr + 1'b1;
					end
				endcase
			end
		end
	end

	old_meminit <= inj_meminit;
	// start_strk fires ONCE per PRG download — only on the INITIAL walk's
	// falling edge, not on any of the relink mini-walks that follow. Use
	// old_is_relink_walk (same rationale as in the arm-relink block).
	start_strk  <= old_meminit & ~inj_meminit & ~old_is_relink_walk & ~strk_fired_once;
	if (old_meminit & ~inj_meminit & ~old_is_relink_walk & ~strk_fired_once)
		strk_fired_once <= 1;
	if (~old_download & ioctl_download && load_prg)
		strk_fired_once <= 0;

	// Auto-RUN override DISABLED — vanilla auto-RUN works without it, so
	// keep the wiring dormant. Flip the literal back to 96_000_000 to
	// re-enable the 3-second data-path intercept if a future regression
	// puts us back into the zeroed-$0801 race.
	if (~old_download & ioctl_download && load_prg)
		autorun_timer <= 0;
	else if (old_meminit & ~inj_meminit & ~old_is_relink_walk & ~strk_fired_once)
		autorun_timer <= 27'd0;           // DISABLED (was 96_000_000)
	else if (|autorun_timer)
		autorun_timer <= autorun_timer - 1'b1;
	// Hold BRAM/cache invalid throughout the ioctl download and the following
	// inj_meminit zero-page init. A 1-cycle pulse after meminit was not enough:
	// BRAM retained KERNAL RAMTAS zeros at $0801+ because ioctl writes only hit
	// SDRAM (via io_cycle), not BRAM. Holding bram_invalidate high for the full
	// download window clears bram_pgvalid and keeps cache_flush asserted so the
	// first post-download CPU read misses BRAM/cache and fills from SDRAM.
	bram_inval_hold <= ioctl_download | inj_meminit;
	if (old_meminit & ~inj_meminit) begin
		dbg_inj_fall_cnt <= dbg_inj_fall_cnt + 1'b1;
		dbg_strk_cnt <= dbg_strk_cnt + 1'b1;
		dbg_inj_end_lo <= inj_end[7:0];
		dbg_inj_end_hi <= inj_end[15:8];
	end
	// CPU-side $0801 write trap — count CPU writes at $0801 after download+meminit
	// so we can tell if BASIC/KERNAL is overwriting the PRG byte.
	// Use dbg_cpu_addr/dbg_cpu_we (direct CPU signals) rather than the
	// bus-muxed c64_addr/ram_we, which can reflect VIC/REU/IO accesses
	// and wash out the PC hint.
	if (!dbg_cpu_we && dbg_cpu_addr != 16'h0801)
		prev_c64_addr <= dbg_cpu_addr;     // last-read CPU addr (≈ nearby PC)
	if (!ioctl_download && !inj_meminit && dbg_cpu_we && dbg_cpu_addr == 16'h0801) begin
		dbg_cpu_wr_0801_cnt  <= dbg_cpu_wr_0801_cnt + 1'b1;
		dbg_cpu_wr_0801_data <= c64_data_out;
		// Snapshot PC only on FIRST write. prev_c64_addr is the most
		// recent non-$0801 read address — for STA abs that's the
		// operand-hi fetch (PC+2), close enough to identify the routine.
		if (dbg_cpu_wr_0801_cnt == 0) begin
			dbg_cpu_wr_0801_pc_lo <= prev_c64_addr[7:0];
			dbg_cpu_wr_0801_pc_hi <= prev_c64_addr[15:8];
		end
	end
	
	old_st0 <= status[17];
	if (~old_st0 & status[17]) cart_attached <= 0;
	
	if (!erasing && force_erase) begin
		erasing <= 1;
		ioctl_load_addr <= 0;
	end

	if (erasing && !ioctl_req_wr) begin
		erase_to <= erase_to + 1'b1;
		if (&erase_to) begin
			if (ioctl_load_addr < ({erase_cram, 16'hFFFF}))
				ioctl_req_wr <= 1;
			else begin
				erasing <= 0;
				erase_cram <= 0;
			end
		end
	end
end

reg        start_strk = 0;
reg        bram_inval_hold = 0;  // held high during ioctl_download + inj_meminit
reg        reset_keys = 0;
reg [10:0] key = 0;
always @(posedge clk_sys) begin
	reg  [3:0] act = 0;
	reg        joy_finish = 0;
	reg [17:0] joy_last = 0;
	reg [17:0] joy_key;
	int        to;

	reset_keys <= 0;

	joy_key =(joy[9:8] == 3) ?
				(joy[0] ? 18'h005 : joy[1] ? 18'h006 : joy[2] ? 18'h004 : joy[3] ? 18'h00C  :
				 joy[4] ? 18'h003 : joy[5] ? 18'h00B : joy[6] ? 18'h083 : joy[7] ? 18'h00A  : 18'h0):
				(joy[9]) ?
				(joy[0] ? 18'h016 : joy[1] ? 18'h01E : joy[2] ? 18'h026 : joy[3] ? 18'h025  :
			    joy[4] ? 18'h02E : joy[5] ? 18'h045 : joy[6] ? 18'h035 : joy[7] ? 18'h031  : 18'h0):
				(joy[0] ? 18'h174 : joy[1] ? 18'h16B : joy[2] ? 18'h172 : joy[3] ? 18'h175  : 
				 joy[4] ? 18'h05A : joy[5] ? 18'h029 : joy[6] ? 18'h076 : joy[7] ? 18'h2276 : 18'h0);
	
	if(~reset_n) {joy_finish, act} <= 0;

	if(joy[9:8]) begin
		joy_finish <= 1;
		if(!joy[7:0] && joy_last) begin
			joy_last <= 0;
			reset_keys <= 1;
		end
		else if(!joy_last[8:0] && joy_key) begin
			to <= to + 1'd1;
			if(joy_last[17:9] != joy_key[17:9]) begin
				joy_last[17:9] <= joy_key[17:9];
				key <= joy_key[17:9];
				key[9] <= 1;
				key[10] <= ~key[10];
			end
			else if(to > 640000 && joy_last[8:0] != joy_key[8:0]) begin
				joy_last[8:0] <= joy_key[8:0];
				key <= joy_key[8:0];
				key[9] <= 1;
				key[10] <= ~key[10];
			end
		end
		else begin
			to <= 0;
		end
	end
	else if(joy_finish) begin
		joy_last   <= 0;
		key        <= 0;
		key[10]    <= ps2_key[10];
		joy_finish <= 0;
		reset_keys <= 1;
	end
	else if(act) begin
		to <= to + 1;
		if(to > 1280000) begin
			to <= 0;
			act <= act + 1'd1;
			case(act)
				// PS/2 scan codes
				 1: key <= 'h2d;  // R
				 3: key <= 'h3c;  // U
				 5: key <= 'h31;  // N
				 7: key <= 'h5a;  // <RETURN>
				 9: key <= 'h00;
				10: act <= 0;
			endcase
			key[9]  <= act[0];
			key[10] <= (act >= 9) ? ps2_key[10] : ~key[10];
		end
	end
	else begin
		to <= 0;
		key <= {ps2_key[10], ps2_key[9] & disk_ready, ps2_key[8:0]};
	end
	if(start_strk & ~status[50]) begin
		act <= 1;
		key <= 0;
	end
end

assign SDRAM_CKE  = 1;

wire [7:0] sdram_data;

sdram sdram
(
	.sd_addr(SDRAM_A),
	.sd_data(SDRAM_DQ),
	.sd_ba(SDRAM_BA),
	.sd_cs(SDRAM_nCS),
	.sd_we(SDRAM_nWE),
	.sd_ras(SDRAM_nRAS),
	.sd_cas(SDRAM_nCAS),
	.sd_clk(SDRAM_CLK),
	.sd_dqm({SDRAM_DQMH,SDRAM_DQML}),

	.clk(clk64),
	.init(~pll_locked),
	.refresh(refresh),
	// SDRAM routing: REU DMA uses reu_ram_active to route addr/we/din during
	// STATE_PROC_RAM. During reu_ram_active=1, ALL cart_ce pulses route through
	// reu_ram_addr/we/dout. A separate reu_ram_active_d (1-cycle delayed) CE
	// pulse ensures the first SDRAM access after mux transition has stable inputs.
	.addr( io_cycle ? (cart_mem_req ? cart_addr   : io_cycle_addr ) : (reu_ram_active ? reu_ram_addr : scpu_sdram_addr) ),
	.ce  ( io_cycle ? (cart_mem_req ? cart_ce     : io_cycle_ce   ) : cart_ce     ),
	.we  ( io_cycle ? (cart_mem_req ? cart_we     : io_cycle_we   ) : (reu_ram_active ? reu_ram_we : cart_we) ),
	.din ( io_cycle ? (cart_mem_req ? cart_wrdata : io_cycle_data ) : (reu_ram_active ? reu_ram_dout : cart_wrdata) ),
	.dout( sdram_data ),
	.dout_hi( sdram_data_hi ),
	.dout_lo( sdram_data_lo ),
	.dout_reu( sdram_data_reu )
);

wire  [7:0] sdram_data_hi;
wire  [7:0] sdram_data_lo;

wire  [7:0] c64_data_out;
wire  [7:0] c64_data_in;
wire [15:0] c64_addr;
wire        c64_pause;
wire        refresh;
wire        ram_ce;
wire        ram_we;
wire        nmi_ack;
wire        freeze_key;
wire        mod_key;

wire        IOE;
wire        IOF;
wire        IOF_raw;  // IOF without io_enable gating — for REU cpu_cs
// Phase-aligned cpu_we / cpu_addr / cpu_dout latched at IOF_raw edge.
// CPU writes are 1-cycle in turbo mode; without these, reu.v's edge
// detector samples cpu_we AFTER the write phase ended → all writes look
// like reads. iof_*_latched carry the cycle-N values into cycle N+1 to
// match IOF_raw's 1-cycle pipeline delay.
wire        iof_we_latched;
wire [15:0] iof_addr_latched;
wire  [7:0] iof_dout_latched;
wire        iof_fall_pulse;
wire        iof_detect_diag;  // combinational iof_detect (diagnostic)
wire        romL;
wire        romH;
wire        UMAXromH;

wire [17:0] audio_l,audio_r;
wire  [7:0] r,g,b;

wire        ntsc = status[2];

// REU ioctl diagnostic counter
reg [23:0] reu_ioctl_cnt = 0;
// Also capture ioctl_index when download starts
reg [7:0] reu_ioctl_idx = 0;
always @(posedge clk_sys) if (ioctl_download && ioctl_wr && ioctl_addr == 0) reu_ioctl_idx <= ioctl_index;
// Capture last ioctl write address and data (for verifying SDRAM write path)
reg [24:0] reu_ioctl_last_addr = 0;
reg  [7:0] reu_ioctl_last_data = 0;
// Capture first byte data
reg  [7:0] reu_ioctl_byte0_data = 0;
always @(posedge clk_sys) begin
    if (ioctl_download && ioctl_wr && load_reu) begin
        reu_ioctl_last_addr <= ioctl_load_addr;
        reu_ioctl_last_data <= ioctl_data;
    end
    if (ioctl_download && ioctl_wr && load_reu && reu_ioctl_cnt == 24'h000000)
        reu_ioctl_byte0_data <= ioctl_data;
end

// ---- SDRAM write presentation counter ----
// Counts every time the SDRAM mux presents an io_cycle WRITE (addr[24]=1 = REU space).
// If this matches reu_ioctl_cnt, the io_cycle→SDRAM write pipeline is working.
reg [23:0] dbg_iowr_count = 0;       // total io_cycle writes presented to SDRAM
reg [24:0] dbg_iowr_first_addr = 0;  // now: LAST write address (updated every write)
reg  [7:0] dbg_iowr_first_data = 0;  // now: LAST write data
// Sticky: was bram_inval_hold ever 1?
reg        dbg_bi_seen = 0;
// Sticky: did ANY io_cycle write have addr[24:16] != 0 (outside bank 0)?
reg        dbg_iowr_nonzero_bankhi = 0;
reg [7:0]  dbg_iowr_bankhi_val = 0;   // capture the offending [23:16] byte
// SDRAM-interface-level counter: fires ONLY when the actual SDRAM write
// for $000801 lands at the sdram module inputs. If count=0, the write
// never reached SDRAM even though io_cycle consume fired.
reg  [7:0] dbg_sdram_0801_cnt = 0;
reg  [7:0] dbg_sdram_0801_data = 0;
// v66 probe: count io_cycle writes that actually landed at bank $00, pages
// $80..$8E during ioctl_download. Expected = 3840 ($0F00). If less, writes
// were silently dropped on the io_cycle→sdram path for this page range.
reg [15:0] dbg_dl_wr_80_8E = 0;
reg        old_download_wr = 0;
always @(posedge clk_sys) begin
    old_download_wr <= ioctl_download;
    if (~old_download_wr & ioctl_download) dbg_dl_wr_80_8E <= 0;
    if (io_cycle && io_cycle_ce && io_cycle_we && !cart_mem_req) begin
        dbg_iowr_count <= dbg_iowr_count + 1'd1;
        dbg_iowr_first_addr <= io_cycle_addr;
        dbg_iowr_first_data <= io_cycle_data;
        if (io_cycle_addr[23:16] != 8'h00 && !dbg_iowr_nonzero_bankhi) begin
            dbg_iowr_nonzero_bankhi <= 1;
            dbg_iowr_bankhi_val <= io_cycle_addr[23:16];
        end
        if (io_cycle_addr == 25'h0000801) begin
            dbg_sdram_0801_cnt  <= dbg_sdram_0801_cnt + 1'b1;
            dbg_sdram_0801_data <= io_cycle_data;
        end
        if (ioctl_download
            && io_cycle_addr[24:16] == 9'h000
            && io_cycle_addr[15:8] >= 8'h80
            && io_cycle_addr[15:8] <= 8'h8E)
            dbg_dl_wr_80_8E <= dbg_dl_wr_80_8E + 1'b1;
    end
    if (bram_inval_hold) dbg_bi_seen <= 1;
end

// ---- IOF diagnostic counters (REU register write debugging) ----
// Track each stage of the cpuAddr_pre → iof_detect → IOF_raw → reu_cs chain
// to identify where REU register writes from BASIC are getting lost.
reg [15:0] dbg_dfxx_cpu_cnt = 0;     // CPU cycles where dbg_cpu_addr[15:8]==$DF
reg [15:0] dbg_dfxx_we_cnt  = 0;     // CPU cycles where $DFxx AND dbg_cpu_we
reg [15:0] dbg_iof_det_cnt  = 0;     // rising edges of iof_detect (combinational)
reg [15:0] dbg_iof_raw_cnt  = 0;     // rising edges of IOF_raw (registered)
reg        iof_det_d        = 0;
reg        iof_raw_d        = 0;
reg  [7:0] dbg_dfxx_last_we_lo = 0;  // low byte of last $DFxx address with we=1
reg  [7:0] dbg_dfxx_last_we_data = 0; // data byte of last $DFxx write
// coincidence: cycles where iof_detect (dfxx AND addr_hi_816=0) AND cpuWe=1
reg [15:0] dbg_iof_we_coinc = 0;
// latched iof_we_r visible from c64.sv clock domain (for comparison)
reg [15:0] dbg_iof_we_latched_hi_cnt = 0;
reg        iof_we_latched_d = 0;
// Overlap check: cycles where IOF_raw=1 AND iof_we_latched=1. If this is
// 0, the two signals never align at reu.v's sampling point. If non-zero,
// reu.v's edge detection should have captured the write.
reg [15:0] dbg_iof_cs_we_overlap = 0;
// What iof_we_latched looks like AT the moment IOF_raw rises
reg        dbg_iof_we_at_raw_rise = 0;
reg [15:0] dbg_iof_we_at_raw_rise_cnt = 0;
reg        iof_raw_d2 = 0;
always @(posedge clk_sys) begin
    iof_det_d <= iof_detect_diag;
    iof_raw_d <= IOF_raw;
    iof_we_latched_d <= iof_we_latched;
    if (dbg_cpu_addr[15:8] == 8'hDF) begin
        dbg_dfxx_cpu_cnt <= dbg_dfxx_cpu_cnt + 1'd1;
        if (dbg_cpu_we) begin
            dbg_dfxx_we_cnt <= dbg_dfxx_we_cnt + 1'd1;
            dbg_dfxx_last_we_lo   <= dbg_cpu_addr[7:0];
            dbg_dfxx_last_we_data <= c64_data_out;
        end
    end
    if (iof_detect_diag && !iof_det_d) dbg_iof_det_cnt <= dbg_iof_det_cnt + 1'd1;
    if (IOF_raw && !iof_raw_d)         dbg_iof_raw_cnt <= dbg_iof_raw_cnt + 1'd1;
    if (iof_detect_diag && dbg_cpu_we) dbg_iof_we_coinc <= dbg_iof_we_coinc + 1'd1;
    if (iof_we_latched && !iof_we_latched_d) dbg_iof_we_latched_hi_cnt <= dbg_iof_we_latched_hi_cnt + 1'd1;
    if (IOF_raw && iof_we_latched) dbg_iof_cs_we_overlap <= dbg_iof_cs_we_overlap + 1'd1;
    iof_raw_d2 <= IOF_raw;
    if (IOF_raw && !iof_raw_d2) begin
        dbg_iof_we_at_raw_rise <= iof_we_latched;
        if (iof_we_latched) dbg_iof_we_at_raw_rise_cnt <= dbg_iof_we_at_raw_rise_cnt + 1'd1;
    end
end

// ---- SDRAM readback after REU ioctl ----
// After REU download completes, schedule one io_cycle READ from REU_ADDR
// and capture sdram_data. This verifies writes independently of CPU path.
// NOTE: reu_rb_pending and reu_rb_active are driven from the main io_cycle
// always block (line ~824) to avoid multiple-driver errors. Only the capture
// logic (reu_rb_cyc, reu_rb_data, reu_rb_done) lives here.
reg        reu_rb_pending = 0;    // readback pending (set here, cleared in io_cycle block)
reg        reu_rb_active = 0;     // readback in progress (set in io_cycle block)
reg  [7:0] reu_rb_cyc = 0;       // v71: widened 3→8 — capture at [7] = ~8 clk_sys after io_cycle rising to allow full SDRAM CAS-2 read cycle (5 cycles) plus margin
reg  [7:0] reu_rb_data = 8'hEE;  // captured SDRAM data (sentinel $EE = not yet read)
reg        reu_rb_done = 0;       // readback complete
reg [24:0] reu_rb_addr = 25'h1020000; // target address for readback (default = REU bank $02:$0000)
reg        prg_dl_seen = 0;       // v68: latched while ioctl_download&&load_prg
reg  [7:0] dbg_prg_rb_arm_cnt = 0; // v68: count of times PRG readback was armed
reg        old_inj_meminit_rb = 0; // v69: edge detector for inj_meminit falling edge
reg  [7:0] dbg_prg_rb_cap_cnt = 0; // v70: count of times capture branch fired after PRG arm
reg  [7:0] sniff_8B94         = 8'hAA; // v72: sdram_data 5 clk after cart_ce rising + addr match
reg  [5:0] sniff_match_pipe   = 6'd0;  // v72: 6-stage delay for cart_ce→sdram_data
reg        last_cart_ce_sn    = 0;     // v72: cart_ce rising-edge detector

// ---- POKE-triggered SDRAM write test ----
// POKE $DF1D,value → write value to REU_ADDR via io_cycle (tests write path)
// POKE $DF1E,value → write value to REU_ADDR+1 via io_cycle
// After write, auto-triggers readback from REU_ADDR → reu_rb_data
// Then LDA long $010000 (bank $01, addr $0000) should read the written value.
reg        dbg_wr_pending = 0;    // write test pending
reg [24:0] dbg_wr_addr = 0;      // address to write
reg  [7:0] dbg_wr_data = 0;      // data to write

// ---- POKE-triggered SDRAM peek register (2026-04-25) ----
// Repurposes $DF1D/$DF1E/$DF1F write path (the dbg_wr SDRAM-write-test slot)
// as a 24-bit address latch + readback trigger. Reads the SDRAM byte at any
// 24-bit address into reu_rb_data ($DF1B). Also rebroadcasts the byte +
// a sequence counter into the UART W: field so we can observe contents
// while the CPU is hung (CPU pokes can't run, but pre-armed peek can).
//
// Sequence (BASIC):
//   POKE $DF1D, lo : POKE $DF1E, mid : POKE $DF1F, hi   ' arm
//   ... (peek auto-rearms after each capture, ~every io_cycle slot)
//   PEEK($DF1B) returns the byte; UART W: shows {peek_seq, peek_data}
//
// peek_addr[23:16]==0 → bank $00 (BRAM/SDRAM bank-$00 mirror)
// peek_addr[23:16]!=0 → SuperRAM/REU bank N at offset peek_addr[15:0]
reg [23:0] peek_addr  = 24'h000000; // 24-bit peek target (bank+offset)
reg  [7:0] peek_seq   =  8'hA5;      // cold-boot marker: W:[15:8]=$A5 confirms new RBF actually loaded
reg        peek_armed =  1'b0;        // set on $DF1F write; gates auto-rearm
reg  [7:0] peek_data  =  8'h5A;      // cold-boot marker: W:[7:0]=$5A confirms new RBF actually loaded

// SuperCPU enable: OSD toggle (status[82]). Lets us diagnose
// whether a regression is in the SuperCPU path or our broader
// modifications to the 6510 bus/cache/BRAM plumbing.
wire        supercpu_enable = status[82];
// 2026-04-25 diagnostic: status[82] previously also fed scpu_rom_opt, which
// kept scpu_rom_overlay='1' from boot for SCPU-ON. That suppresses
// bram_hit_native for $8000-$FFFF and forces upper-half reads through
// buslogic→SDRAM. The overlay GHDL bench (p65c816_asterix_overlay_tb.vhd)
// reproduces Asterix's $C003 hang when $C000-$FEFF reads are stale.
// Default rom_opt='0' so overlay starts off; SCPU-aware software can still
// arm the kickstart ROM via $D07E.
wire        scpu_rom_opt    = 1'b0;
wire        supercpu_emul;                  // '1' = 65C816 in 6502 emulation mode
wire        supercpu_cycle;                 // '1' during CPU SDRAM access slot
wire  [7:0] supercpu_bank;                  // current bank byte (A23-A16)
wire        cpu_has_bus;                    // '1' when CPU owns bus (not VIC)

// SuperCPU 16MB SDRAM address: for non-bank-$00 accesses, prepend the bank byte.
// Bank $00 maps to base 64KB (normal C64 RAM). Banks $01-$FF map to SuperRAM.
// SuperRAM lives in the REU SDRAM region (REU_ADDR = 0x1000000, bit[24]=1).
// This allows REU images (.reu) loaded via OSD to be directly accessible through
// 65816 24-bit addressing (e.g., LDA $024000 reads REU offset $024000).
// The mapping: SDRAM addr = {1, bank, addr16} — direct 1:1 with .reu file.
// Bank $02 addr $0000 = REU offset $020000 (matching doom.reu data layout).
// The first 128KB (banks $00-$01) of the .reu file are the SRAM shadow (usually empty).
// Note: scpu_rom_en in fpga64_buslogic handles banks $F0-$FF reads from ROM BRAM;
// writes to ROM-bank addresses go to SDRAM shadow (harmless, never read back).
//
// TIMING FIX: Use dbg_cpu_addr (= cpuAddr_pre, direct CPU output) instead of
// c64_addr (= systemAddr, muxed between cpuAddr/vicAddr every cycle boundary).
// c64_addr has a long combinational path through the bus mux that violates the
// clk32→clk64 timing constraint (-24ns slack). dbg_cpu_addr comes directly from
// CPU registers (only changes at enableCpu), so the path is just tCQ + wiring.
// Same pattern used for REU cpu_addr (see line ~691).
// Concatenation replaces addition: REU_ADDR + {0, bank, addr} = {1, bank, addr}
// since REU_ADDR = 25'h1000000 (bit[24]=1) and the operand has bit[24]=0.
// SDRAM address mux MUST be combinational — registering it introduces
// a 1-cycle latency that breaks STA/LDA long round-trips (verified 2026-04-02).
wire [24:0] scpu_superram_addr = {1'b1, supercpu_bank, dbg_cpu_addr};

// Route non-bank-$00 CPU accesses to SuperRAM SDRAM region.
// Gate on cpu_has_bus to prevent VIC reads (VIC0) from going to SuperRAM
// when supercpu_bank retains a non-$00 value from the last CPU instruction.
// NOTE: scpu_sdram_addr MUST be combinational — registering it introduces
// a 1-cycle latency that causes stale addresses when BRAM hits fire at CPUB.
// v72: CPU-side sniffer for SDRAM reads at $008B94. Captures sdram_data
// 5 clk_sys after cart_ce rising with matching scpu_sdram_addr, bypassing
// the flaky io_cycle readback path. If CPU ever reads $008B94 during
// Asterix phase-1 pass 52, we latch SDRAM's output.
always @(posedge clk_sys) begin
    last_cart_ce_sn <= cart_ce;
    sniff_match_pipe <= {sniff_match_pipe[4:0],
        (cart_ce & ~last_cart_ce_sn & ~cart_we & ~io_cycle
         & (scpu_sdram_addr == 25'h0008B94))};
    if (sniff_match_pipe[5]) sniff_8B94 <= sdram_data;
end

wire [24:0] scpu_sdram_addr = (supercpu_enable && cpu_has_bus && (supercpu_bank != 8'h00))
                               ? scpu_superram_addr
                               : cart_addr;

// SuperRAM SDRAM diagnostic: latch the mux conditions at cart_ce rising edge
// when the CPU is accessing a non-bank-$00 address. This tells us whether
// the address was correctly routed to SuperRAM or fell through to cart_addr.
reg [7:0] dbg_sram_bank = 0;      // bank byte at CE time
reg [7:0] dbg_sram_data = 0;      // SDRAM data at next enableCpu
reg       dbg_sram_has_bus = 0;    // cpu_has_bus at CE time
reg       dbg_sram_reu = 0;       // reu_ram_active at CE time
reg       dbg_sram_io = 0;        // io_cycle at CE time
reg       last_cart_ce_dbg = 0;
// DMA debug: sticky capture of reu_ram_active during DMA
// Latches reu_ram_active and reu_ram_we the first time cart_ce fires
// while dma_req=1. Read via dbg_sram_reu. Clear on reset.
reg       dbg_dma_ram_active_seen = 0;  // sticky: was reu_ram_active ever 1?
reg       dbg_dma_ram_we_seen = 0;      // sticky: was reu_ram_we ever 1?
reg [3:0] dbg_dma_ce_count = 0;        // count of cart_ce during DMA
// Extended DMA debug: track reu_ram_active independently of cart_ce
reg       dbg_dma_ram_active_ever = 0;  // sticky: reu_ram_active ever 1 during dma_req?
reg [3:0] dbg_dma_ram_active_clks = 0; // count of clk32 cycles reu_ram_active was 1
always @(posedge clk_sys) begin
	last_cart_ce_dbg <= cart_ce;
	if (cart_ce && !last_cart_ce_dbg && supercpu_bank != 8'h00) begin
		dbg_sram_bank <= supercpu_bank;
		dbg_sram_has_bus <= cpu_has_bus;
		dbg_sram_reu <= reu_ram_active;
		dbg_sram_io <= io_cycle;
	end
	// DMA debug capture
	if (~reset_n) begin
		dbg_dma_ram_active_seen <= 0;
		dbg_dma_ram_we_seen <= 0;
		dbg_dma_ce_count <= 0;
		dbg_dma_ram_active_ever <= 0;
		dbg_dma_ram_active_clks <= 0;
	end else if (dma_req) begin
		if (cart_ce && !last_cart_ce_dbg) begin
			dbg_dma_ce_count <= dbg_dma_ce_count + 1'd1;
			if (reu_ram_active) dbg_dma_ram_active_seen <= 1;
			if (reu_ram_active && reu_ram_we) dbg_dma_ram_we_seen <= 1;
		end
		// Track reu_ram_active independently of cart_ce timing
		if (reu_ram_active) begin
			dbg_dma_ram_active_ever <= 1;
			if (!(&dbg_dma_ram_active_clks))  // saturate at 15
				dbg_dma_ram_active_clks <= dbg_dma_ram_active_clks + 1'd1;
		end
	end else if (dbg_dma_ce_count != 0) begin
		// DMA just ended — keep sticky values for reading
		// dbg_dma_ce_count stays non-zero as a "DMA happened" flag
	end
end

// Debug infrastructure
wire        dbg_overlay_en = 1'b1;          // Always on (was: status[83])
wire  [1:0] dbg_led_mode   = status[85:84]; // 0=Off, 1=Emulation, 2=CPU Active, 3=CPU Write
wire        dbg_uart_en    = 1'b1;           // Always on (was: status[87])
wire [15:0] dbg_cpu_addr;
wire  [7:0] dbg_cpu_data;
wire        dbg_cpu_we;
wire        dbg_cpu_en;
wire [15:0] dbg_cpu_sp;
wire  [7:0] dbg_cpu_p;
wire  [7:0] dbg_cpu_ir;
wire  [7:0] dbg_cpu_pbr;
wire  [7:0] dbg_cpu_dbr;
wire  [7:0] dbg_cia1_pa;
wire  [7:0] dbg_cia1_pb;
wire [15:0] dbg_scr_wr_addr;
wire [15:0] dbg_scr_wr_pc;
wire [15:0] dbg_0801_pc;
wire [7:0]  dbg_0801_ir;
wire [7:0]  dbg_0801_data_sv;
wire [7:0]  dbg_0801_cnt_sv;
wire  [7:0] dbg_scr_wr_data;
wire  [7:0] dbg_scr_wr_ir;
wire        dbg_scr_zero_hit;
wire  [7:0] dbg_scr_wr_bank;
wire        dbg_scr_arm;
wire        dbg_vic_zero_hit;
wire [15:0] dbg_vic_zero_addr;
wire [15:0] dbg_vic_zero_cpu;
wire [15:0] dbg_vic_zero_sysaddr;
wire        dbg_vic_wr_match;
wire [15:0] dbg_vic_wr_pc;
wire  [7:0] dbg_vic_prearm_cnt;
wire  [7:0] dbg_vic_hit_cnt;
wire  [7:0] dbg_vic_mode;
wire  [7:0] dbg_vic_cpuf_zero_cnt;
wire  [7:0] dbg_vic_cpue_live_zero_cnt;
wire  [7:0] dbg_vic_cpue_hold_zero_cnt;
wire  [7:0] dbg_vic_cpue_mismatch_cnt;
wire        dbg_turbo_en;
wire        dbg_cache_hit_d1;
wire        dbg_enable_cpu_t65;
wire        dbg_cpu_cyc;
wire  [7:0] dbg_diag;
wire [5127:0] dbg_bug_buf;  // 641 bytes: status + 128×(PC16,PBR8,IR8) + 128×P8
wire [15:0] dbg_native_irq_vec;  // native IRQ vector ($FFEE/$FFEF)
wire [15:0] dbg_irq_nmi_count;   // [15:8]=NMI edge count, [7:0]=IRQ edge count
// SuperRAM read-path diagnostic latches (exposed at $DFE9-$DFEF)
wire [15:0] dbg_srr_count;
wire  [7:0] dbg_srr_data;
wire  [7:0] dbg_srr_addr_hi;
wire  [7:0] dbg_srr_cache_bank;
wire  [7:0] dbg_srr_addr_lo;
wire  [7:0] dbg_srr_addr_mid;

// Shadow parameters: Verilog macros -> integer generics for VHDL passing.
// fpga64_sid_iec.vhd has matching DBG_TRACE / DBG_BUS_CAPTURE integer
// generics; keep these in sync (half-gated = dangling signals).
`ifdef DBG_TRACE
  localparam DBG_TRACE_PARAM = 1;
`else
  localparam DBG_TRACE_PARAM = 0;
`endif
`ifdef DBG_BUS_CAPTURE
  localparam DBG_BUS_CAPTURE_PARAM = 1;
`else
  localparam DBG_BUS_CAPTURE_PARAM = 0;
`endif

fpga64_sid_iec #(
	.DBG_TRACE       (DBG_TRACE_PARAM),
	.DBG_BUS_CAPTURE (DBG_BUS_CAPTURE_PARAM)
) fpga64
(
	.clk32(clk_sys),
	.reset_n(reset_n),
	.pause(freeze),
	.pause_out(c64_pause),
	.bios(status[15:14]),
	
	// disk_access gate removed: iec_slow_mode inside fpga64_sid_iec.vhd
	// provides CIA2-based 32ms slowdown during actual IEC operations.
	.turbo_mode(status[47:46]),
	.turbo_speed(status[49:48]),
	.scpu_speed(status[89:88]),
	.supercpu_en(supercpu_enable),
	.supercpu_rom(scpu_rom_opt),
	.bram_invalidate(bram_inval_hold),
	.io_bram_we(io_bram_we_pulse),
	.io_bram_addr(io_cycle_addr[15:0]),
	.io_bram_din(io_cycle_data),
	.autorun_override(autorun_override_active),
	.autorun_link_lo(prg_link_lo),
	.autorun_link_hi(prg_link_hi),
	.dbg_0801_trap_en(~ioctl_download & ~inj_meminit),
	.dbg_0801_pc(dbg_0801_pc),
	.dbg_0801_ir(dbg_0801_ir),
	.dbg_0801_data_out(dbg_0801_data_sv),
	.dbg_0801_cnt(dbg_0801_cnt_sv),
	.supercpu_emul(supercpu_emul),
	.supercpu_cycle(supercpu_cycle),
	.supercpu_bank(supercpu_bank),
	.cpu_has_bus(cpu_has_bus),
	.dbg_cpu_addr(dbg_cpu_addr),
	.dbg_cpu_data(dbg_cpu_data),
	.dbg_cpu_we(dbg_cpu_we),
	.dbg_cpu_en(dbg_cpu_en),
	.dbg_cpu_sp(dbg_cpu_sp),
	.dbg_cpu_p(dbg_cpu_p),
	.dbg_cpu_ir(dbg_cpu_ir),
	.dbg_cpu_pbr(dbg_cpu_pbr),
	.dbg_cpu_dbr(dbg_cpu_dbr),
	.dbg_cia1_pa(dbg_cia1_pa),
	.dbg_cia1_pb(dbg_cia1_pb),
	.dbg_scr_wr_addr(dbg_scr_wr_addr),
	.dbg_scr_wr_pc(dbg_scr_wr_pc),
	.dbg_scr_wr_data(dbg_scr_wr_data),
	.dbg_scr_wr_ir(dbg_scr_wr_ir),
	.dbg_scr_zero_hit(dbg_scr_zero_hit),
	.dbg_scr_wr_bank(dbg_scr_wr_bank),
	.dbg_scr_arm(dbg_scr_arm),
	.dbg_vic_zero_hit(dbg_vic_zero_hit),
	.dbg_vic_zero_addr(dbg_vic_zero_addr),
	.dbg_vic_zero_cpu(dbg_vic_zero_cpu),
	.dbg_vic_zero_sysaddr(dbg_vic_zero_sysaddr),
	.dbg_vic_wr_match(dbg_vic_wr_match),
	.dbg_vic_wr_pc(dbg_vic_wr_pc),
	.dbg_vic_prearm_cnt(dbg_vic_prearm_cnt),
	.dbg_vic_hit_cnt(dbg_vic_hit_cnt),
	.dbg_vic_mode(dbg_vic_mode),
	.dbg_vic_cpuf_zero_cnt(dbg_vic_cpuf_zero_cnt),
	.dbg_vic_cpue_live_zero_cnt(dbg_vic_cpue_live_zero_cnt),
	.dbg_vic_cpue_hold_zero_cnt(dbg_vic_cpue_hold_zero_cnt),
	.dbg_vic_cpue_mismatch_cnt(dbg_vic_cpue_mismatch_cnt),
	.dbg_turbo_en(dbg_turbo_en),
	.dbg_cache_hit_d1(dbg_cache_hit_d1),
	.dbg_enable_cpu_t65(dbg_enable_cpu_t65),
	.dbg_cpu_cyc(dbg_cpu_cyc),
	.dbg_diag(dbg_diag),
	.dbg_bug_buf(dbg_bug_buf),
	.dbg_native_irq_vec(dbg_native_irq_vec),
	.dbg_srr_count(dbg_srr_count),
	.dbg_srr_data(dbg_srr_data),
	.dbg_srr_addr_hi(dbg_srr_addr_hi),
	.dbg_srr_cache_bank(dbg_srr_cache_bank),
	.dbg_srr_addr_lo(dbg_srr_addr_lo),
	.dbg_srr_addr_mid(dbg_srr_addr_mid),
	.dbg_irq_nmi_count(dbg_irq_nmi_count),

	.ps2_key(key),
	.kbd_reset((~reset_n & ~status[1]) | reset_keys),
	.shift_mod(~status[60:59]),

	.ramAddr(c64_addr),
	.ramDout(c64_data_out),
	.ramDin(c64_data_in),
	.sdram_raw(sdram_data),
	.sdram_superram(sdram_data_reu),
	.sdram_hi(sdram_data_hi),
	.sdram_lo(sdram_data_lo),
	.ramCE(ram_ce),
	.ramWE(ram_we),

	.vic_variant(status[35:34]),
	.ntscmode(ntsc),
	.hsync(hsync),
	.vsync(vsync),
	.r(r),
	.g(g),
	.b(b),

	.game(game),
	.exrom(exrom),
	.UMAXromH(UMAXromH),
	.irq_n(1),
	.nmi_n(~nmi),
	.nmi_ack(nmi_ack),
	.freeze_key(freeze_key),
	.tape_play(tape_play),
	.mod_key(mod_key),
	.roml(romL),
	.romh(romH),
	.ioe(IOE),
	.iof(IOF),
	.IOF_raw(IOF_raw),
	.iof_detect_o(iof_detect_diag),
	.iof_we_o(iof_we_latched),
	.iof_addr_o(iof_addr_latched),
	.iof_dout_o(iof_dout_latched),
	.iof_fall_pulse_o(iof_fall_pulse),
	.io_rom(io_rom),
	.io_ext(io_ext_r),     // registered: stable, immune to -10ns timing
	.io_data(io_data_r_sv), // registered: 1-cycle delay, correct for I/O pipeline
	
	.dma_req(dma_req),
	.dma_cycle(dma_cycle),
	.dma_addr(dma_addr),
	.dma_dout(dma_dout),
	.dma_din(dma_din),
	.dma_we(dma_we),
	.irq_ext_n(~reu_irq),

	.cia_mode(status[45]),

	.joya({(pd12_mode && !joy[9:8]) ? joyA_c64[6:5] : 2'b00, joyA_c64[4:0] | {1'b0, pd12_mode[1] & paddle_2_btn, pd12_mode[1] & paddle_1_btn, 2'b00} | {pd12_mode[0] & mouse_btn[0], 3'b000, pd12_mode[0] & mouse_btn[1]}}),
	.joyb({(pd34_mode && !joy[9:8]) ? joyB_c64[6:5] : 2'b00, joyB_c64[4:0] | {1'b0, pd34_mode[1] & paddle_4_btn, pd34_mode[1] & paddle_3_btn, 2'b00} | {pd34_mode[0] & mouse_btn[0], 3'b000, pd34_mode[0] & mouse_btn[1]}}),

	.pot1(pd12_mode[1] ? paddle_1 : pd12_mode[0] ? mouse_x : {8{joyA_c64[5]}}),
	.pot2(pd12_mode[1] ? paddle_2 : pd12_mode[0] ? mouse_y : {8{joyA_c64[6]}}),
	.pot3(pd34_mode[1] ? paddle_3 : pd34_mode[0] ? mouse_x : {8{joyB_c64[5]}}),
	.pot4(pd34_mode[1] ? paddle_4 : pd34_mode[0] ? mouse_y : {8{joyB_c64[6]}}),

	.io_cycle(io_cycle),
	.ext_cycle(ext_cycle),
	.refresh(refresh),

	.sid_ld_clk(clk_sys),
	.sid_ld_addr(sid_ld_addr),
	.sid_ld_data(sid_ld_data),
	.sid_ld_wr(sid_ld_wr),
	.sid_mode(status[22:20]),
	.sid_filter(2'b11),
	.sid_ver({status[16],status[13]}),
	.sid_cfg({status[68:67],status[65:64]}),
	.sid_fc_off_l(status[66] ? (13'h600 - {status[72:70],7'd0}) : 13'd0),
	.sid_fc_off_r(status[69] ? (13'h600 - {status[75:73],7'd0}) : 13'd0),
	.sid_digifix(~status[37]),
	.audio_l(audio_l),
	.audio_r(audio_r),

	.iec_data_o(c64_iec_data),
	.iec_atn_o(c64_iec_atn),
	.iec_clk_o(c64_iec_clk),
	.iec_data_i(drive_iec_data),
	.iec_clk_i(drive_iec_clk),

	.pb_i(pb_i),
	.pb_o(pb_o),
	.pa2_i(pa2_i),
	.pa2_o(pa2_o),
	.pc2_n_o(pc2_n_o),
	.flag2_n_i(flag2_n_i),
	.sp2_i(sp2_i),
	.sp2_o(sp2_o),
	.sp1_i(sp1_i),
	.sp1_o(sp1_o),
	.cnt2_i(cnt2_i),
	.cnt2_o(cnt2_o),
	.cnt1_i(cnt1_i),
	.cnt1_o(cnt1_o),

	.c64rom_addr(ioctl_addr[13:0]),
	.c64rom_data(ioctl_data),
	.c64rom_wr(load_rom && !ioctl_addr[16:14] && ioctl_download && ioctl_wr),

	.cass_write(cass_write),
	.cass_motor(cass_motor),
	.cass_sense(~tape_adc_act & (use_tape ? cass_sense : cass_rtc)),
	.cass_read(tape_adc_act ? ~tape_adc : cass_read)
);

wire [7:0] mouse_x;
wire [7:0] mouse_y;
wire [1:0] mouse_btn;

c1351 mouse
(
	.clk_sys(clk_sys),
	.reset(~reset_n),

	.ps2_mouse(ps2_mouse),
	
	.potX(mouse_x),
	.potY(mouse_y),
	.button(mouse_btn)
);

wire       c64_iec_clk;
wire       c64_iec_data;
wire       c64_iec_atn;

wire       drive_iec_clk  = drive_iec_clk_o  & ext_iec_clk;
wire       drive_iec_data = drive_iec_data_o & ext_iec_data;

wire [7:0] drive_par_i;
wire       drive_stb_i;
wire [7:0] drive_par_o;
wire       drive_stb_o;
wire       drive_iec_clk_o;
wire       drive_iec_data_o;
wire       drive_reset = ~reset_n | status[6] | (load_c1581 & ioctl_download);

wire [1:0] drive_led;
wire       disk_ready;

reg [1:0] drive_mounted = 0;
reg [1:0] old_img_mounted;

always @(posedge clk_sys) begin 
	old_img_mounted <= img_mounted;
	if(img_mounted[0]) drive_mounted[0] <= |img_size;
	if(img_mounted[1]) drive_mounted[1] <= |img_size;
end

wire mounted_0 = ~old_img_mounted[0] & img_mounted[0];
wire mounted_1 = ~old_img_mounted[1] & img_mounted[1];
wire img_readonly_wp = img_readonly | (mounted_0 & status[76]) | (mounted_1 & status[77]);

iec_drive iec_drive
(
	.clk(clk_sys),
	.reset({drive_reset | ((!status[56:55]) ? ~drive_mounted[1] : status[56]),
		     drive_reset | ((!status[58:57]) ? ~drive_mounted[0] : status[58])}),

	.ce(drive_ce),

	.iec_atn_i(c64_iec_atn),
	.iec_data_i(c64_iec_data & ext_iec_data),
	.iec_clk_i(c64_iec_clk & ext_iec_clk),
	.iec_data_o(drive_iec_data_o),
	.iec_clk_o(drive_iec_clk_o),

	.pause(c64_pause),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly_wp),
	.img_type(&ioctl_index[7:6] ? 2'b11 : 2'b01),
	.drive_rpm(status[80:78]),
	.drive_wobble(status[81]),

	.led(drive_led),
	.disk_ready(disk_ready),

	.par_data_i(drive_par_i),
	.par_stb_i(drive_stb_i),
	.par_data_o(drive_par_o),
	.par_stb_o(drive_stb_o),

	.clk_sys(clk_sys),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.rom_addr(load_rom ? (ioctl_addr[15:0] - 16'h4000) : {1'b1,ioctl_addr[14:0]}),
	.rom_data(ioctl_data),
	.rom_wr(((load_rom && ioctl_addr[16:14]) || load_c1581) && ioctl_download && ioctl_wr),
	.rom_std(status[14])
);

reg drive_ce;
always @(posedge clk_sys) begin
	int sum = 0;
	int msum;
	
	msum <= ntsc ? 32727264 : 31527954;

	drive_ce <= 0;
	sum = sum + 16000000;
	if(sum >= msum) begin
		sum = sum - msum;
		drive_ce <= 1;
	end
end

wire disk_parport = ~status[44];

reg disk_access;
always @(posedge clk_sys) begin
	reg c64_iec_clk_old, drive_iec_clk_old, drive_stb_i_old, drive_stb_o_old;
	integer to = 0;

	c64_iec_clk_old <= c64_iec_clk;
	drive_iec_clk_old <= drive_iec_clk;
	drive_stb_i_old <= drive_stb_i;
	drive_stb_o_old <= drive_stb_o;
	
	if(((c64_iec_clk_old != c64_iec_clk) || (drive_iec_clk_old != drive_iec_clk)) || 
		(disk_parport && ((drive_stb_i_old != drive_stb_i) || (drive_stb_o_old != drive_stb_o))))
	begin
		disk_access <= 1;
		to <= 16000000; // 0.5s
	end
	else if(to) to <= to - 1;
	else disk_access <= 0;
end

wire ext_iec_en   = status[25];
wire ext_iec_clk  = USER_IN[2] | ~ext_iec_en;
wire ext_iec_data = USER_IN[4] | ~ext_iec_en;

assign USER_OUT[2] = (c64_iec_clk & drive_iec_clk_o)  | ~ext_iec_en;
assign USER_OUT[3] = (reset_n & ~status[6]) | ~ext_iec_en;
assign USER_OUT[4] = (c64_iec_data & drive_iec_data_o) | ~ext_iec_en;
assign USER_OUT[5] = c64_iec_atn | ~ext_iec_en;
assign USER_OUT[6] = '1;


wire hsync;
wire vsync;
wire hblank;
wire vblank;
wire hsync_out;
wire vsync_out;

video_sync sync
(
	.clk32(clk_sys),
	.pause(c64_pause),
	.hsync(hsync),
	.vsync(vsync),
	.ntsc(ntsc),
	.wide(wide),
	.hsync_out(hsync_out),
	.vsync_out(vsync_out),
	.hblank(hblank),
	.vblank(vblank)
);

// Debug vblank: derive from raw vsync (not affected by c64_pause).
// When the core is paused (OSD freeze), vblank from video_sync stops pulsing,
// which kills the debug overlay and UART. Using the raw VIC vsync ensures
// debug infrastructure always runs.
reg dbg_vblank;
always @(posedge clk_sys) begin
	reg [1:0] vsync_sr;
	vsync_sr <= {vsync_sr[0], vsync};
	dbg_vblank <= vsync_sr[0] & ~vsync_sr[1]; // rising edge of vsync
end

// 2026-04-25: W: field repurposed for peek register output.
// W[15:8] = peek_seq (8-bit sequence counter, increments per readback completion)
// W[7:0]  = peek_data (live SDRAM byte at peek_addr, refreshed every io_cycle slot)
// To use: pre-arm via POKE $DF1D/$DF1E/$DF1F (lo/mid/hi), then watch UART W:.
// peek_seq advances → readbacks are firing; static W → arm did not stick or
// io_cycle is starved. Default peek_addr=0 reads bank $00 zero page (innocuous).
wire [15:0] last_doom_addr = {peek_seq, peek_data};
wire [15:0] _req_mismatch  = dbg_req_set_cnt - dbg_req_cons_cnt;
wire  [7:0] last_doom_bank = _req_mismatch[7:0];

reg hq2x160;
always @(posedge clk_sys) begin
	reg old_vsync;

	old_vsync <= vsync_out;
	if (!old_vsync && vsync_out) begin
		hq2x160 <= (status[10:8] == 2);
	end
end

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg [2:0] div;
	reg       lores;

	div <= div + 1'b1;
	if(&div) lores <= ~lores;
	ce_pix <= (~lores | ~hq2x160) && !div;
end

wire scandoubler = status[10:8] || forced_scandoubler;

assign CLK_VIDEO = clk64;
assign VGA_SL    = (status[10:8] > 2) ? status[9:8] - 2'd2 : 2'd0;
assign VGA_F1    = 0;

reg [9:0] vcrop;
reg wide;
always @(posedge CLK_VIDEO) begin
	vcrop <= 0;
	wide <= 0;
	if(HDMI_WIDTH >= (HDMI_HEIGHT + HDMI_HEIGHT[11:1]) && !scandoubler) begin
		if(HDMI_HEIGHT == 480)  vcrop <= 240;
		if(HDMI_HEIGHT == 600)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 720)  vcrop <= 240;
		if(HDMI_HEIGHT == 768)  vcrop <= 256; // NTSC mode has 250 visible lines only!
		if(HDMI_HEIGHT == 800)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 1080) vcrop <= 10'd216;
		if(HDMI_HEIGHT == 1200) vcrop <= 240;
	end
	else if(HDMI_WIDTH >= 1440 && !scandoubler) begin
		// 1920x1440 and 2048x1536 are 4:3 resolutions and won't fit in the previous if statement ( width > height * 1.5 )
		if(HDMI_HEIGHT == 1440) vcrop <= 240;
		if(HDMI_HEIGHT == 1536) vcrop <= 256;
	end
end


wire [1:0] ar = status[5:4];
wire vcrop_en = status[32];
wire vga_de;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? (wide ? 12'd340 : 12'd400) : (ar - 1'd1)),
	.ARY((!ar) ? 12'd300 : 12'd0),
	.CROP_SIZE(vcrop_en ? vcrop : 10'd0),
	.CROP_OFF(0),
	.SCALE(status[31:30])
);

wire freeze_sync;
reg freeze;
always @(posedge clk_sys) begin
	reg old_sync;

	old_sync <= freeze_sync;
	if (~reset_n)
		freeze <= 0;
	else if(old_sync ^ freeze_sync)
		freeze <= OSD_STATUS & status[42];
end

assign HDMI_FREEZE = freeze;

// Debug overlay: renders CPU state as hex in top border.
// DBG_OVERLAY=0 removes the overlay module + all its `dbg_*` readers.
// In release mode ovl_active is tied to 0 so the video mixer bypasses the
// overlay entirely, and the r/g/b channels pass through unchanged.
wire       ovl_active;
wire [7:0] ovl_r, ovl_g, ovl_b;

`ifdef DBG_OVERLAY
debug_overlay debug_ovl
(
	.clk(clk_sys),
	.enable(dbg_overlay_en),
	.hblank(hblank),
	.vblank(vblank),
	.cpu_addr(dbg_cpu_addr),
	.cpu_data(dbg_cpu_data),
	.cpu_we(dbg_cpu_we),
	.cpu_en(dbg_cpu_en),
	.emu_mode(supercpu_emul),
	.bank_addr(supercpu_bank),
	.supercpu(supercpu_enable),
	.cpu_sp(dbg_cpu_sp),
	.cpu_p(dbg_cpu_p),
	.cpu_ir(dbg_cpu_ir),
	.cia1_pa(dbg_cia1_pa),
	.cia1_pb(dbg_cia1_pb),
	.scr_wr_addr(dbg_scr_wr_addr),
	.scr_wr_pc(dbg_scr_wr_pc),
	.scr_wr_data(dbg_scr_wr_data),
	.scr_wr_ir(dbg_scr_wr_ir),
	.scr_zero_hit(dbg_scr_zero_hit),
	.scr_wr_bank(dbg_scr_wr_bank),
	.scr_arm(dbg_scr_arm),
	.vic_zero_hit(dbg_vic_zero_hit),
	.vic_zero_addr(dbg_vic_zero_addr),
	.vic_zero_cpu(dbg_vic_zero_cpu),
	.vic_zero_sysaddr(dbg_vic_zero_sysaddr),
	.vic_wr_match(dbg_vic_wr_match),
	.vic_wr_pc(dbg_vic_wr_pc),
	.vic_prearm_cnt(dbg_vic_prearm_cnt),
	.vic_hit_cnt(dbg_vic_hit_cnt),
	.vic_mode(dbg_vic_mode),
	.vic_cpuf_zero_cnt(dbg_vic_cpuf_zero_cnt),
	.vic_cpue_live_zero_cnt(dbg_vic_cpue_live_zero_cnt),
	.vic_cpue_hold_zero_cnt(dbg_vic_cpue_hold_zero_cnt),
	.vic_cpue_mismatch_cnt(dbg_vic_cpue_mismatch_cnt),
	.turbo_en(dbg_turbo_en),
	.cache_hit_pulse(dbg_cache_hit_d1),
	.enable_cpu_pulse(dbg_enable_cpu_t65),
	.overlay_active(ovl_active),
	.overlay_r(ovl_r),
	.overlay_g(ovl_g),
	.overlay_b(ovl_b)
);
`else
// DBG_OVERLAY=0: overlay disabled, video passthrough.
assign ovl_active = 1'b0;
assign ovl_r      = 8'h00;
assign ovl_g      = 8'h00;
assign ovl_b      = 8'h00;
`endif

wire [7:0] r_ovl = ovl_active ? ovl_r : r;
wire [7:0] g_ovl = ovl_active ? ovl_g : g;
wire [7:0] b_ovl = ovl_active ? ovl_b : b;

// Debug UART: streams CPU state as ASCII hex lines at each vblank.
// DBG_UART=0 removes the formatter + serializer; UART_TXD keeps the
// existing functional UART path (the UART override block below is also
// guarded so it can't force dbg_uart_tx).
wire       dbg_uart_tx;
wire       dbg_uart_busy;
wire [7:0] dbg_uart_data;
wire       dbg_uart_send;

`ifdef DBG_UART
debug_uart_fmt debug_fmt
(
	.clk(clk_sys),
	.reset(~reset_n),
	.enable(dbg_uart_en),
	.vblank(dbg_vblank),  // Use pause-independent vblank for UART
	.cpu_addr(dbg_cpu_addr),
	.cpu_data(dbg_cpu_data),
	.cpu_bank(supercpu_bank),
	.cpu_sp(dbg_cpu_sp),
	.cpu_p(dbg_cpu_p),
	.cpu_ir(dbg_cpu_ir),
	.cpu_emul(supercpu_emul),
	.cpu_pbr(dbg_cpu_pbr),
	.cpu_dbr(dbg_cpu_dbr),
	.turbo_en(dbg_turbo_en),
	// Override diag with DMA debug after ANY DMA (when ce_count > 0)
	// bit7=dma_ram_active_ever, bit6=dma_ram_active_seen(at CE), bit5=dma_ram_we_seen,
	// bit4:1=dma_ram_active_clks, bit0=turbo_en
	.diag(dbg_dma_ce_count != 0 ? {dbg_dma_ram_active_ever, dbg_dma_ram_active_seen, dbg_dma_ram_we_seen, dbg_dma_ram_active_clks, dbg_diag[0]} : dbg_diag),
	.cache_hit_pulse(dbg_cache_hit_d1),
	.enable_cpu_pulse(dbg_enable_cpu_t65),
	.cpu_cyc_pulse(dbg_cpu_cyc),
	.native_irq_vec(last_doom_addr),   // W:xxxx = last addr when PBR!=00 (freezes at crash)
	.crash_bank(last_doom_bank),       // L:xx = last bank when PBR!=00 (freezes at crash)
	.vic_irq(~dbg_diag[7]),  // dbg_diag[7] = NOT_irq_vic, invert for active-high
	.trace_buf(dbg_bug_buf),           // 641-byte crash trace ring buffer (128 entries × 5 bytes + status)
	.tx_data(dbg_uart_data),
	.tx_send(dbg_uart_send),
	.tx_busy(dbg_uart_busy)
);

debug_uart_tx #(.CLK_FREQ(32000000), .BAUD(115200)) debug_tx
(
	.clk(clk_sys),
	.reset(~reset_n),
	.enable(dbg_uart_en),
	.data(dbg_uart_data),
	.send(dbg_uart_send),
	.tx(dbg_uart_tx),
	.busy(dbg_uart_busy)
);
`else
// DBG_UART=0: debug UART disabled, tx held idle-high (TTL serial idle state).
assign dbg_uart_tx   = 1'b1;
assign dbg_uart_busy = 1'b0;
assign dbg_uart_data = 8'h00;
assign dbg_uart_send = 1'b0;
`endif

video_mixer #(.GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),

	.hq2x(~status[10] & (status[9] ^ status[8])),
	.scandoubler(scandoubler),
	.gamma_bus(gamma_bus),

	.ce_pix(ce_pix),
	.R(r_ovl),
	.G(g_ovl),
	.B(b_ovl),
	.HSync(hsync_out),
	.VSync(vsync_out),
	.HBlank(hblank),
	.VBlank(vblank),

	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(freeze_sync),

	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

wire        opl_en = status[12];
wire [15:0] opl_out;
wire  [7:0] opl_dout;
opl3 #(.OPLCLK(47291931)) opl_inst
(
	.clk(clk_sys),
	.clk_opl(clk48),
	.rst_n(reset_n & opl_en),

	.addr(c64_addr[4]),
	.dout(opl_dout),
	.we(ram_we & IOF & opl_en & c64_addr[6] & ~c64_addr[5]),
	.din(c64_data_out),

	.sample_l(opl_out)
);

reg ioe_we, iof_we;
always @(posedge clk_sys) begin
	reg old_ioe, old_iof;

	old_ioe <= IOE;
	ioe_we <= ~old_ioe & IOE & ram_we;

	old_iof <= IOF;
	iof_we <= ~old_iof & IOF & ram_we;
end

reg [11:0] sid_ld_addr = 0;
reg [15:0] sid_ld_data = 0;
reg        sid_ld_wr   = 0;
always @(posedge clk_sys) begin
	sid_ld_wr <= 0;
	if(ioctl_wr && load_flt && ioctl_addr < 6144) begin
		if(ioctl_addr[0]) begin
			sid_ld_data[15:8] <= ioctl_data;
			sid_ld_addr <= ioctl_addr[12:1];
			sid_ld_wr <= 1;
		end
		else begin
			sid_ld_data[7:0] <= ioctl_data;
		end
	end
end

//DigiMax
reg [8:0] dac_l, dac_r;
always @(posedge clk_sys) begin
	reg [8:0] dac[4];
	reg [3:0] act;

	if(!status[41:40] || ~reset_n) begin
		dac <= '{0,0,0,0};
		act <= 0;
	end
	else if((status[41] ? iof_we : ioe_we) && ~c64_addr[2]) begin
		dac[c64_addr[1:0]] <= c64_data_out;
		if(c64_data_out) act[c64_addr[1:0]] <= 1;
	end

	// guess mono/stereo/4-chan modes
	if(act<2) begin
		dac_l <= dac[0] + dac[0];
		dac_r <= dac[0] + dac[0];
	end
	else if(act<3) begin
		dac_l <= dac[1] + dac[1];
		dac_r <= dac[0] + dac[0];
	end
	else begin
		dac_l <= dac[1] + dac[2];
		dac_r <= dac[0] + dac[3];
	end
end

localparam [3:0] comp_f1 = 4;
localparam [3:0] comp_a1 = 2;
localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b1 = comp_x1 * comp_a1;

function [15:0] compr; input [15:0] inp;
	reg [15:0] v, v1;
	begin
		v  = inp[15] ? (~inp) + 1'd1 : inp;
		v1 = (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
		v  = v1;
		compr = inp[15] ? ~(v-1'd1) : v;
	end
endfunction

reg [15:0] alo,aro;
always @(posedge clk_sys) begin
	reg [16:0] alm,arm;
	reg [15:0] cout;
	reg [15:0] cin;
	
	cin  <= opl_out - {{3{opl_out[15]}},opl_out[15:3]};
	cout <= compr(cin);

	alm <= {cout[15],cout} + {audio_l[17],audio_l[17:2]} + {2'b0,dac_l,6'd0} + {cass_snd, 9'd0};
	arm <= {cout[15],cout} + {audio_r[17],audio_r[17:2]} + {2'b0,dac_r,6'd0} + {cass_snd, 9'd0};
	alo <= ^alm[16:15] ? {alm[16], {15{alm[15]}}} : alm[15:0];
	aro <= ^arm[16:15] ? {arm[16], {15{arm[15]}}} : arm[15:0];
end

assign AUDIO_L = alo;
assign AUDIO_R = aro;
assign AUDIO_S = 1;
assign AUDIO_MIX = status[19:18];

//------------- TAP -------------------

wire       tap_download = ioctl_download & load_tap;
wire       tap_reset    = ~reset_n | tap_download | status[23] | !tap_last_addr | cass_finish | (cass_run & ((tap_last_addr - tap_play_addr) < 80));
wire       tap_loaded   = (tap_play_addr < tap_last_addr);                                    // ^^ auto-unload if motor stopped at the very end ^^
wire       tap_play_btn = status[7] | tape_play;
wire       tape_play;

reg [24:0] tap_play_addr;
reg [24:0] tap_last_addr;
reg  [1:0] tap_wrreq;
wire       tap_wrfull;
reg  [1:0] tap_version;
reg        tap_start;

always @(posedge clk_sys) begin
	reg io_cycleD;
	reg read_cyc;

	io_cycleD <= io_cycle;
	tap_wrreq <= tap_wrreq << 1;

	if(tap_reset) begin
		//C1530 module requires one more byte at the end due to fifo early check.
		tap_last_addr <= tap_download ? ioctl_addr+2'd2 : 25'd0;
		tap_play_addr <= 0;
		tap_start     <= ~status[39] & tap_download;
		read_cyc      <= 0;
	end
	else begin
		tap_start <= 0;
		if (~io_cycle & io_cycleD & ~tap_wrfull & tap_loaded) read_cyc <= 1;
		if (io_cycle & io_cycleD & read_cyc) begin
			tap_play_addr <= tap_play_addr + 1'd1;
			read_cyc <= 0;
			tap_wrreq[0] <= 1;
		end
	end
end

wire cass_write;
wire cass_motor;
wire cass_sense;
wire cass_read;
wire cass_run;
wire cass_finish;
wire cass_snd = cass_read & ~cass_run & status[11] & ~cass_finish;

c1530 c1530
(
	.clk32(clk_sys),
	.restart_tape(tap_reset),
	.wav_mode(0),
	.tap_version(tap_version),
	.host_tap_in(sdram_data),
	.host_tap_wrreq(tap_wrreq[1]),
	.tap_fifo_wrfull(tap_wrfull),
	.tap_fifo_error(cass_finish),
	.cass_read(cass_read),
	.cass_write(cass_write),
	.cass_motor(cass_motor),
	.cass_sense(cass_sense),
	.cass_run(cass_run),
	.osd_play_stop_toggle(tap_play_btn | tap_start),
	.ear_input(0)
);

reg use_tape;
always @(posedge clk_sys) begin
	integer to = 0;

	if(to) to <= to - 1;
	else use_tape <= status[36];

	if(tap_loaded | ~cass_sense) begin
		use_tape <= 1;
		to <= 128000000; //4s
	end
end

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + (cass_sense ? 4'd1 : 4'd8);
wire tape_led = tap_loaded && (act_cnt[26] ? (~(~cass_sense & cass_motor) && act_cnt[25:18] > act_cnt[7:0]) : act_cnt[25:18] <= act_cnt[7:0]);

wire tape_adc, tape_adc_act;
ltc2308_tape #(.CLK_RATE(32000000)) ltc2308_tape
(
  .clk(clk_sys),
  .ADC_BUS(ADC_BUS),
  .dout(tape_adc),
  .active(tape_adc_act)
);

//------------- USER PORT -----------------

wire [7:0] pb_i, pb_o;
wire       pa2_i, pa2_o;
wire       pc2_n_o;
wire       flag2_n_i;
wire       sp2_i, sp2_o, sp1_o, sp1_i;
wire       cnt2_i, cnt2_o, cnt1_o, cnt1_i;

always_comb begin
	pa2_i       = 1;
	flag2_n_i   = 1;
	sp1_i       = 1;
	sp2_i       = 1;
	cnt1_i      = 1;
	cnt2_i      = 1;
	pb_i        = 8'hFF;
	UART_TXD    = 1;
	UART_RTS    = 0;
	UART_DTR    = 0;
	drive_par_i = 8'hFF;
	drive_stb_i = 1;
	USER_OUT[0] = 1;
	USER_OUT[1] = 1;

	if(disk_parport & disk_access) begin
		drive_par_i = pb_o;
		drive_stb_i = pc2_n_o;
		pb_i        = drive_par_o;
		flag2_n_i   = drive_stb_o;
	end
	else if(status[43]) begin
		UART_TXD  = pa2_o & uart_int;
		flag2_n_i = uart_rxd;
		sp2_i     = uart_rxd;
		pb_i[0]   = uart_rxd;
		UART_RTS  = ~pb_o[1] & uart_int;
		UART_DTR  = ~pb_o[2] & uart_int;
		pb_i[4]   = ~uart_dsr;
		pb_i[6]   = ~uart_cts;
		pb_i[7]   = ~uart_dsr;

		USER_OUT[1] = pa2_o | uart_int;

		if(~status[51]) begin
			UART_TXD = pa2_o & sp1_o & uart_int;
			pb_i[7]  = cnt2_o;
			cnt2_i   = pb_o[7];

			USER_OUT[1] = (pa2_o & sp1_o) | uart_int;
		end
	end
	else begin
		pb_i[5:0] = {!joyD_c64[6:4], !joyC_c64[6:4], pb_o[7] ? ~joyC_c64[3:0] : ~joyD_c64[3:0]};
	end

`ifdef DBG_UART
	// Debug UART override: when enabled, takes over UART_TXD for debug output
	if (dbg_uart_en) begin
		UART_TXD = dbg_uart_tx;
	end
`endif
end

wire uart_int = ~status[33];

reg uart_rxd, uart_dsr, uart_cts;
always @(posedge clk_sys) begin
	reg rxd1, rxd2, dsr1, dsr2, cts1, cts2;

	rxd1 <= uart_int ? UART_RXD : USER_IN[0]; rxd2 <= rxd1; if(rxd1 == rxd2) uart_rxd <= rxd2;
	cts1 <= UART_CTS & uart_int; cts2 <= cts1; if(cts1 == cts2) uart_cts <= cts2;
	dsr1 <= UART_DSR & uart_int; dsr2 <= dsr1; if(dsr1 == dsr2) uart_dsr <= dsr2;
end

wire rtcF83_sda;
rtcF83 #(16000000, 0) rtcF83
(
	.clk(clk_sys),
	.ce(drive_ce),
	.reset(~reset_n | use_tape),
	.RTC(RTC),
	.scl_i(cass_write),
	.sda_i(cass_motor),
	.sda_o(rtcF83_sda)
);

reg use_rtc = 0;
always @(posedge clk_sys) begin
	reg [20:0] to = 0;

	if(to) to <= to - 1'd1;
	use_rtc <= |to;

	if(cass_write) to <= '1;
end

wire cass_rtc = ~(rtcF83_sda & use_rtc & cass_motor);

endmodule
