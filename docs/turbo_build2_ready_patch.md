# Build-2 (single-tracker turbo) — patch-ready spec

> **SHELVED 2026-05-30 — DO NOT BUILD.** Build-1 (the controller-only
> precondition) was HW-FALSIFIED: the Build-C page-mode controller alone
> regresses Doom ($00:000A), and the improved sim shows page-mode delivers no
> speedup on interleaved (ZP-heavy) workloads. Build-2 layers a speedup on a
> broken+payoff-less controller → pointless. Kept only as a record of the
> single-tracker design. See `docs/turbo_build1_controller_falsified.md` and
> `docs/turbo_throughput_sim_findings.md` §ITER 2. Real >4 MHz path = Milestone B.

---


**Gate:** apply ONLY after Build-1 (controller-only bisect) boots Doom + native
clean on HW. Build-1 = aafa4a4 Build-C `sdram_pm.v` + `fast_path` wired,
arbiter unchanged (`sdram_hit_pred<='0'`, alt-slots off). If Build-1 wedges
Doom, the controller itself is the problem → do NOT proceed to Build-2.

Sim oracle (`sim/turbo_throughput_tb`, validated 2026-05-30): mode-2 single
tracker = **7.99 MHz / 0 stale** in every config incl. refresh-stress; mode-1
private predictor = 6.98 MHz but **1026 stale** under refresh (the Doom BRK).
Build-2 implements mode-2: arbiter derives HIT from the controller's exposed
tracker (single source of truth), never its own private predictor.

## 1. `C64_MiSTer/rtl/sdram_pm.v` — expose the internal tracker
After the `data_valid` output port (line ~72), add:
```verilog
	output reg          data_valid,
	// Build-2 (2026-05-30): expose internal page-mode row tracker so the
	// arbiter derives HIT from the SAME source of truth (single tracker).
	// Regs are stable between accesses → multi-bit CDC safe-by-protocol
	// (arbiter samples only at a CPU-slot ce-edge, long after settle).
	output     [12:0]   o_last_row,
	output     [ 1:0]   o_last_bank,
	output              o_last_row_valid
```
Near the other `assign`s (bottom of file), add:
```verilog
assign o_last_row       = last_row;
assign o_last_bank      = last_bank;
assign o_last_row_valid = last_row_valid;
```

## 2. `C64_MiSTer/c64.sv` — route tracker out of sdram_pm, into fpga64
Declare (near the `scpu_fast_path` wire):
```verilog
wire [12:0] sdram_last_row;
wire [1:0]  sdram_last_bank;
wire        sdram_last_row_valid;
```
Add to the `sdram_pm sdram(...)` instantiation (after `.fast_path`):
```verilog
	.fast_path( sdram_fast_path ),
	.o_last_row( sdram_last_row ),
	.o_last_bank( sdram_last_bank ),
	.o_last_row_valid( sdram_last_row_valid )
```
Add to the `fpga64_sid_iec` instantiation new input ports:
```verilog
	.sdram_last_row( sdram_last_row ),
	.sdram_last_bank( sdram_last_bank ),
	.sdram_last_row_valid( sdram_last_row_valid ),
```

## 3. `C64_MiSTer/rtl/fpga64_sid_iec.vhd`
### 3a. entity ports (near `scpu_fast_path_o : out std_logic`)
```vhdl
	scpu_fast_path_o           : out std_logic;
	sdram_last_row             : in  unsigned(12 downto 0);
	sdram_last_bank            : in  unsigned(1 downto 0);
	sdram_last_row_valid       : in  std_logic
```

### 3b. replace `sdram_hit_pred <= '0';` (line ~3225)
Single-tracker combinational compare against the controller's tracker, using
the SAME SuperRAM bank/row slicing the old private predictor used
(addr_hi_816(6:5) bank, addr_hi_816(4:0)&systemAddr(15:8) row):
```vhdl
sdram_hit_pred <= '1' when (scpu_fast_path = '1'
                       and sdram_last_row_valid = '1'
                       and sdram_last_bank = unsigned(addr_hi_816(6 downto 5))
                       and sdram_last_row  = unsigned(addr_hi_816(4 downto 0)
                                                      & systemAddr(15 downto 8)))
                  else '0';
```
The private predictor regs (`sdram_pred_*`) + their VIC0 clear + the
update block at ~3354-3362 become DEAD (nobody reads them). Leave them (zero
harm; Quartus prunes) OR strip for clarity — stripping is optional, not
required for correctness.

### 3c. re-enable alt-slot fire (alt_fire_r2 block, ~3414-3422)
Uncomment to:
```vhdl
	if (sysCycle = CYCLE_CPU2 or sysCycle = CYCLE_CPU6
	    or sysCycle = CYCLE_CPUA or sysCycle = CYCLE_CPUE)
	   and scpu_fast_path = '1'
	   and cs_ram = '1'
	   and sdram_busy_cnt <= "001" then
		alt_fire_r2 <= '1';
	else
		alt_fire_r2 <= '0';
	end if;
```
Leave `alt_fire_r` (CPU1/5/9/D) gated off — alt_fire_r2 (CPU3/7/B/F sample at
CPU2/6/A/E) is the proven path. busy_cnt preload already loads "001" on
hit_pred=1 (line ~3346), which is what makes the `<= "001"` predicate pass.

## 4. `C64_MiSTer/C64.sdc` — CDC for the tracker crossing
The tracker regs cross clk64→clk32. They are stable between accesses, so a
false-path (or 2-cycle multicycle) is correct. Check existing constraints for
the sdram_ready 2-FF pattern and mirror. Candidate:
```
set_false_path -from [get_registers {*sdram*last_row*}] -to [get_registers {*}]
set_false_path -from [get_registers {*sdram*last_bank*}] -to [get_registers {*}]
set_false_path -from [get_registers {*sdram*last_row_valid*}] -to [get_registers {*}]
```
Verify register name patterns against a Build-1 fit report before trusting the
wildcards.

## Validation order for Build-2
1. Doom autoload (`tools/deploy_and_probe_doom.py`) — MUST stay clean (0 stale
   is the whole point; a BRK = tracker compare wrong).
2. native speed bench — expect >4 MHz on sequential SuperRAM code.
3. Lorenz scpu (`tools/lorenz_run.py scpu`) — 100%, no regression.
4. Lorenz t65 — 100% (controller affects both modes).
