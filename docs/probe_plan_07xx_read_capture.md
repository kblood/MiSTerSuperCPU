# Probe plan: capture last CPU read in `$00:$0700-$00:$07FF`

**Why:** Doom is wedged in `$41:$DB9A` polling `CMP $00:$0707, X / BCS+3 / BNE-2`.
We don't know X at runtime, and we don't know what byte the wait condition
is comparing against. This probe tells us both.

See `project_doom_wait_loop_at_41db9a.md` and `docs/session_handoff.md`
for the full context.

## RTL changes (3 files, ~30 lines)

### 1. `C64_MiSTer/rtl/fpga64_sid_iec.vhd`

Add two signals next to the existing `wr02_*_r` signals (around line 994):

```vhdl
-- 2026-05-09 doom-wait probe: capture the LAST cpu read in $00:$0700-$07FF
-- (page-$07 is where Doom's wait loop at $41:$DB9A polls $00:$0707+X
-- with `df 07 07 00 / b0 03 / d0 fe`). Show what byte the wait sees.
signal rd07xx_addr_r    : std_logic_vector(7 downto 0)   := (others => '0');
signal rd07xx_data_r    : std_logic_vector(7 downto 0)   := (others => '0');
```

In the read-capture process (around line 2476, the `if enableCpu = '1' and
cpuWe_pre = '0' then` block), append:

```vhdl
-- doom-wait probe: latch reads in $00:$07xx
if cpuAddr_pre(15 downto 8) = x"07"
   and (supercpu_en = '0' or addr_hi_816 = x"00") then
    rd07xx_addr_r <= std_logic_vector(cpuAddr_pre(7 downto 0));
    rd07xx_data_r <= std_logic_vector(cpuDi);
end if;
```

In the entity port list (around line 552, after `dbg_wr02_x`), add:

```vhdl
dbg_rd07xx_addr      : out std_logic_vector(7 downto 0);
dbg_rd07xx_data      : out std_logic_vector(7 downto 0);
```

In the architecture's port-out assignments (search for `dbg_wr02_x <= wr02_x_r;`):

```vhdl
dbg_rd07xx_addr <= rd07xx_addr_r;
dbg_rd07xx_data <= rd07xx_data_r;
```

In the reset clause (around line 2378, alongside `wr02_pc_r <= ...;`):

```vhdl
rd07xx_addr_r <= (others => '0');
rd07xx_data_r <= (others => '0');
```

### 2. `C64_MiSTer/rtl/debug/debug_pkg.svh`

Add to `dbg_pool_t` (after `wr02_x` field around line 465):

```systemverilog
// 2026-05-09 doom-wait probe — captures last $00:$07xx read.
logic  [7:0] rd07xx_addr;
logic  [7:0] rd07xx_data;
```

### 3. `C64_MiSTer/c64.sv`

Wire the new ports through whatever instantiates fpga64_sid_iec — just
follow the wr02_x pattern for naming.

### 4. `C64_MiSTer/rtl/debug/debug_uart_pool_fmt.sv`

Replace `VC:####` (positions 194-201, which is irq_vec_count — already
saturated in Doom-wait state, low diagnostic value) with `R7:####`
encoding `addr_lo data` as 4 hex nibbles:

```systemverilog
// REPLACE positions 194..201 (VC:####) with R7:####
8'd194: line_byte = " ";
8'd195: line_byte = "R";
8'd196: line_byte = "7";
8'd197: line_byte = ":";
8'd198: line_byte = hex_nibble(lat_rd07addr[7:4]);
8'd199: line_byte = hex_nibble(lat_rd07addr[3:0]);
8'd200: line_byte = hex_nibble(lat_rd07data[7:4]);
8'd201: line_byte = hex_nibble(lat_rd07data[3:0]);
```

Add the latches (next to `lat_d012_wc` around line 95):

```systemverilog
reg  [7:0] lat_rd07addr;
reg  [7:0] lat_rd07data;
```

Add the latch assignments (in the vblank-rising-edge block alongside
`lat_d012_wc <= pool.d012_write_cycles;`):

```systemverilog
lat_rd07addr <= pool.rd07xx_addr;
lat_rd07data <= pool.rd07xx_data;
```

## How to read the probe

`R7:LLDD` tells you the LAST address+data fetched in $00:$07xx, where
LL is the low byte of the address and DD is the byte returned.

If pc_main (N field) sticks at `$41:$DB93` and the wait loop runs
~50× per second, R7 will continuously refresh. Two cases:

- **R7 locked at one value (e.g. `R7:0707FF`)**: the wait loop is
  reading exactly that address every iteration. The byte `$FF` is
  what the CMP compares against A. Look at the full CMP context
  around `$41:$DB96` to know what A holds.

- **R7 cycling through a small set**: there are multiple memory
  reads in the inner loop (e.g. an indexed lookup that walks).

## Updating the analyzer

`tools/doom_uart_analyze.py` should learn the new field. Add an entry
to `LINE_RE`:

```python
'R7': re.compile(r'R7:([0-9A-F]+)'),
```

And include it in the `last:` print line.

## Acceptance criterion

Build, deploy, run `tools/doom_full_run.py`. Look at `R7` field at
t=240s. Two outcomes:

- **R7 stays at `R7:07XXYY`** for several samples → wait condition
  identified at exactly `$00:$07XX = YY`. Next step: search doom.reu
  for code that should write that address (use byte-pattern census
  in `project_doom_wait_loop_at_41db9a.md`).

- **R7 cycles through many values** → wait loop has a non-trivial
  inner pattern (indexed lookup, multiple reads). Need richer probe
  (e.g. a 4-deep ring of $07xx reads).

## Caveats

- The latch fires for ANY read in `$00:$07xx`, including page-$07
  reads from non-wait-loop code paths. If the IRQ handler reads
  $07xx, the field will jitter. Mitigation: gate on `addr_hi_816 =
  x"00"` only when `supercpu_en='1'` (already in the snippet above).
- 4 hex chars per UART line is cheap (4 bytes, no line-len
  expansion).
- ALM cost: ~16 flops + small comparator → trivial.
