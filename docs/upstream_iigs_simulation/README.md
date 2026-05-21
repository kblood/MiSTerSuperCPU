# Upstream handoff: NMOS 6502 RMW double-write quirk for `iigs_simulation`

Subject: P65C816 in 65816 emulation mode (E=1) currently does CMOS-style
single-write read-modify-write, but Apple II software (and CMD SuperCPU
software on Commodore 64) relies on the NMOS 6502 double-write quirk for
I/O acknowledgement via `INC $C0xx` / `INC $D019` style ack instructions.

This is **not a bug in the WDC 65C816 datasheet** — real WDC silicon also
does single-write CMOS RMW in emu mode. It is, however, a compatibility
gap that every successful 65C816-based system targeting NMOS-era software
has had to bridge: real CMD SuperCPU does it; real Apple IIgs does it (the
"Slow ROM" path on Mega II works around it for I/O space accesses); VICE
xscpu64 does it.

The MiSTer C64 SuperCPU fork (`P65C816.vhd`) just landed and verified this
fix as commit
[`af99997`](../../C64_MiSTer/rtl/65C816/P65C816.vhd) — Dragon's Lair now
renders correctly on hardware. Translating the patch into
`iigs_simulation/rtl/65C816/P65C816.sv` should be a 1:1 port: the
microcode field names, RMW opcode whitelist (28 opcodes), and bus mux
shape are identical between the two cores.

## Concrete failure mode (Commodore 64 case)

Dragon's Lair runs an FLI raster IRQ handler at `$317E`/`$327E`:

```
$317e: EE 19 D0    INC $D019    ; ack VIC raster IRQ (NMOS quirk)
$327e: EE 19 D0    INC $D019    ; ack VIC raster IRQ (NMOS quirk)
```

VIC-II's `$D019` IRST register clears the corresponding pending bit on a
*write* with that bit = 1. NMOS 6502 RMW does:

| Cycle | NMOS 6502 / T65            | CMOS 65C816 (current iigs P65C816) |
|------:|----------------------------|-------------------------------------|
|   1–3 | fetch `EE 19 D0`           | same                                |
|     4 | read `$D019` → e.g. `$F1`  | same → T(7:0) = `$F1`               |
|     5 | **WRITE OLD `$F1`**        | internal ALU only, NO write         |
|     6 | WRITE NEW `$F2`            | WRITE NEW `$F2`                     |

On NMOS the cycle-5 write of `$F1` (bit 0 = 1) clears IRST. On CMOS
single-write, only `$F2` (bit 0 = 0) reaches `$D019` — IRST stays
asserted forever, IRQ_N never rises, the handler keeps re-entering the
same level pulse, and FLI multiplexer state diverges. Game shows
corrupted/scrambled output.

Apple IIgs equivalent: `INC $C00x` for soft-switch ack on Apple II
slot-card I/O is the exact same pattern. Any title that does this on
real 6502 hardware (most Apple II games and Apple II-compatible
applications) will see broken I/O ack on `iigs_simulation` running in
emu mode. Severity depends on which soft switches the title pokes via
RMW — likely silent corruption rather than outright hang for most
titles, but will hit anything that uses INC/DEC on a hardware register
expecting bit-state-on-bus to ack.

## VICE oracle (independent confirmation)

VICE's xscpu64 `65816core.c` documents this in comments and implements
NMOS double-write under a `defined(C64SC)` guard. See VICE source at
`vice/src/c64sc/cpu/65816core.c` if you want a second oracle.

## The fix (concept)

Detect the modify cycle of memory RMW opcodes by microcode signature
plus opcode whitelist; gate on `EF=1`; on the modify cycle: drive
`D_OUT = T(7:0)` (T still holds the OLD just-read value), force
`WE` low (the cycle is normally `OUT_BUS=000` = no bus output), and
zero the `ADDR_INC` so the address points at AA+0 (operand byte) not
AA+1 (slot-4 default for 16-bit second-byte access).

Native mode (`EF=0`) is unchanged — CMOS single-write semantics are
preserved for native 65C816 software that may depend on them.

## VHDL patch (the source-of-truth)

Full patch attached as
[`0001-P65C816-NMOS-RMW-double-write-in-emu-mode-fixes-Drag.patch`](./0001-P65C816-NMOS-RMW-double-write-in-emu-mode-fixes-Drag.patch).
Total: ~62 lines added in `P65C816.vhd`, no other files touched, no
new ports, no new microcode entries.

Three change sites:

1. **Two combinational signals** — `rmw_decode` (28-opcode whitelist —
   identical to the existing `rmw` variable iigs has at `P65C816.sv:967`)
   and `rmw_modify_cycle` (gate on `EF=1` + RMW + microcode-field
   pattern).
2. **`D_OUT` mux override** — prepend a `rmw_modify_cycle` arm that
   selects `T(7:0)`.
3. **`WE` process override** — extend the OUT_BUS-driven WE gate to
   also fire under `rmw_modify_cycle`.
4. **Address-process override** — zero `ADDR_INC` under
   `rmw_modify_cycle`.

## SystemVerilog translation skeleton (for `iigs_simulation/rtl/65C816/P65C816.sv`)

The microcode field names, T loading semantics, and bus mux match VHDL
1:1. Skeleton port — the `rmw` whitelist already exists at line 967, so
the heavy lifting is already there:

```systemverilog
// near other combinational gating signals (top of always_comb / module body)
logic rmw_modify_cycle;
assign rmw_modify_cycle = (EF == 1'b1)
                        && rmw                            // already exists at L967
                        && (MC.LOAD_T   == 2'b10)
                        && (MC.OUT_BUS  == 3'b000)
                        && (MC.BUS_CTRL[5:3] == 3'b100);

// override D_OUT (currently at line ~578); add as the first ternary arm:
assign D_OUT = rmw_modify_cycle                         ? T[7:0] :
               (MC.OUT_BUS == 3'b001)                   ? {P[7], P[6], (P[5] | EF), ( EF ? ~GotInterrupt : P[4] ), P[3:0]} :
               (MC.OUT_BUS == 3'b010 & MC.BYTE_SEL[1])  ? PC[15:8] :
               // ... rest of existing mux unchanged ...

// override WE (currently around line 590-595):
always @(*) begin
   WE = 1'b1;
   if ((MC.OUT_BUS != 3'b000) || rmw_modify_cycle)
      WE = 1'b0;
end

// override ADDR_INC (in the address-bus always_comb where ADDR_INC is built):
ADDR_INC = {14'd0, MC.ADDR_INC};
if (rmw_modify_cycle)
   ADDR_INC = '0;
```

(Caveat: the iigs SV file uses `rmw` as a *variable* inside an
`always_comb` block at line 964; it may need to be hoisted to a
module-level `logic` or duplicated in the gating expression. The VHDL
patch did the same — defined a separate `rmw_decode` signal alongside
the existing per-process `rmw` variable.)

## Existing precedents in the iigs SV that this fits with

The iigs P65C816.sv already has E-gated quirk overrides at lines 651,
663, 673, 687 — `if (EF == 1'b1 && IR == 8'hXX && MC.ADDR_BUS == 4'bYYYY)`.
The proposed RMW patch is the same pattern, just generalized to 28
opcodes and using the existing `rmw` whitelist instead of single-IR
matching.

## Test signature

If you want to validate the patch in isolation:

```
LDA #$F1
STA $C000          ; (or any RAM address)
INC $C000          ; should produce TWO bus writes:
                   ;   cycle 5: $F1
                   ;   cycle 6: $F2
                   ; with WE low on both.
```

In the buggy (pre-patch) state only the cycle-6 `$F2` write appears.

For Apple II-software regression you can target any title that uses
soft-switch RMW — `INC $C0xx` patterns are widespread in early DOS 3.3
era code and copy-protection routines.

## Hardware confirmation (MiSTer C64 SuperCPU)

Build md5: `8bac63045c49003a955ae68549e043ab`. Branch:
[`vanilla-cpu-swap`](https://github.com/kblood/MiSTerSuperCPU/tree/vanilla-cpu-swap).

UART per-frame counters (T65 NMOS reference vs. P65C816 in emu mode,
post-fix):

| Counter                                    | T65          | P65C816 pre-fix | P65C816 post-fix |
|--------------------------------------------|--------------|-----------------|------------------|
| `VW` ($D019 writes seen by VIC)            | 2.00/frame   | 1.67/frame      | **2.00/frame**   |
| `AC` (`resetRasterIrq` pulses)             | 1.00/frame   | 0.00/frame      | **1.00/frame**   |
| `AW` (writes with cpuDo bit 0 = 1)         | 15.99/frame  | 0.00/frame      | **15.99/frame**  |

Visual: Dragon's Lair intro castle (FLI multicolor) renders correctly
on SCPU under v272. Side-by-side T65 vs. SCPU PNG hashes are
bit-identical for tight non-animated workloads (decomp_stress.prg INC
zp inner loop) and visually equivalent for animated content (DL,
Asterix title, Doom loader).

## Contact

Patch author: Kasper Olesen (`kaspersolesen@gmail.com`).
Co-authored with Claude (Anthropic), commit message includes attribution.

License: same as the rest of `iigs_simulation` / MiSTer C64 source —
free to apply, modify, redistribute.
