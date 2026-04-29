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
//   - C64.qsf (default debug build) leaves DEBUG_RELEASE undef. If
//     DEBUG_ENABLE is also undef, the file behaves as a no-op header so
//     the build still succeeds; subsequent commits will turn DEBUG_ENABLE
//     on by default in C64.qsf.
//
// This file is intentionally minimal at commit 1 ("scaffold"). Later
// commits add: dbg_pool_t struct (commit 2), DBG_LAYOUT_* layout id
// constants (commit 6).

`ifndef DEBUG_PKG_SVH
`define DEBUG_PKG_SVH

// Master release gate -- if set, undef every fine-grained DBG_* macro.
`ifdef DEBUG_RELEASE
  `undef DEBUG_ENABLE
  `undef DBG_OVERLAY
  `undef DBG_CAP_REU
  `undef DBG_CAP_VIC_WR
  `undef DBG_CAP_CPU_STATE
  `undef DBG_CAP_FRAME
  `undef DBG_UART
`endif

`endif // DEBUG_PKG_SVH
