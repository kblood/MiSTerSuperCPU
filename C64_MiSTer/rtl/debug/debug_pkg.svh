// debug_pkg.svh
//
// Macro defaults, layout constants, and the dbg_pool_t struct that carries
// captured diagnostic state from cap_*.sv modules to the renderer.
//
// Include with `include "debug_pkg.svh"` from c64.sv (the SEARCH_PATH in
// debug.qip puts rtl/debug/ on the include path).
//
// Macro polarity:
//   - C64_release.qsf defines DEBUG_RELEASE=1 -> everything below resolves
//     to "undef" and synthesis collapses every overlay/capture wire.
//   - C64.qsf (default debug build) defines DEBUG_ENABLE=1 which cascades
//     to DBG_OVERLAY + DBG_CAP_* unless the caller has set finer gates
//     before this header is included.

`ifndef DEBUG_PKG_SVH
`define DEBUG_PKG_SVH

// ---- Master release gate ----------------------------------------------
// If set, undef every fine-grained DBG_* macro so synthesis collapses the
// overlay/capture trees to direct passthroughs.
`ifdef DEBUG_RELEASE
  `undef DEBUG_ENABLE
  `undef DBG_OVERLAY
  `undef DBG_CAP_REU
  `undef DBG_CAP_VIC_WR
  `undef DBG_CAP_CPU_STATE
  `undef DBG_CAP_FRAME
  `undef DBG_UART
`endif

// ---- DEBUG_ENABLE cascade ---------------------------------------------
// Turning on DEBUG_ENABLE in the qsf is shorthand for "I want overlay +
// every capture domain unless I've already opted out below". A user who
// wants only one capture lane can `\`define DBG_OVERLAY` + a single
// `DBG_CAP_*` in the qsf and leave DEBUG_ENABLE undef.
`ifdef DEBUG_ENABLE
  `ifndef DBG_OVERLAY
    `define DBG_OVERLAY
  `endif
  `ifndef DBG_CAP_REU
    `define DBG_CAP_REU
  `endif
  `ifndef DBG_CAP_VIC_WR
    `define DBG_CAP_VIC_WR
  `endif
  `ifndef DBG_CAP_CPU_STATE
    `define DBG_CAP_CPU_STATE
  `endif
  `ifndef DBG_CAP_FRAME
    `define DBG_CAP_FRAME
  `endif
`endif

// ---- Layout id (commit 6 will populate) -------------------------------
// DBG_LAYOUT picks which fields render where. Layout 1 = DL triage.
`ifndef DBG_LAYOUT
  `define DBG_LAYOUT 1
`endif

// ---- Pool struct -------------------------------------------------------
// Carries captured diagnostic state from cap_*.sv modules to the
// renderer. Only declared when DBG_OVERLAY is set so release builds
// don't pay the type-check overhead.
`ifdef DBG_OVERLAY
typedef struct packed {
  // REU domain
  logic [15:0] reu_c64_addr;     // $DF02/$DF03 - C64 target
  logic [23:0] reu_reu_addr;     // $DF04/$DF05/$DF06 - REU side
  logic [15:0] reu_length;       // $DF07/$DF08
  logic  [7:0] reu_cmd;          // $DF01 last command
  logic [15:0] reu_fetch_count;  // FETCH/STASH execution counter

  // VIC + bus domain
  logic  [7:0] vic_d018;         // screen + char-bitmap pointer
  logic  [7:0] vic_d016;         // X-scroll + control2
  logic  [7:0] vic_dd00;         // CIA2 PA - VIC bank select
  logic [11:0] vic_raster;       // raster line decimal (0..311 PAL)

  // CPU domain
  logic [23:0] cpu_pc;           // 24-bit (PBR:PC) for SCPU, $00:PC for T65
  logic  [7:0] cpu_p;            // status flags (NV-MX-DIZC) - SCPU only
  logic  [7:0] cpu_dbr;          // data bank register - SCPU only
  logic  [7:0] cpu_flags;        // {ba,dma,turbo,scpu_en,1mhz,iec,emu,e_flag}

  // Misc
  logic [15:0] frame_count;      // ticks each vsync rising edge
} dbg_pool_t;
`endif

`endif // DEBUG_PKG_SVH
