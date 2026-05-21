# P65C816 — comparison vs VICE C64 emulator (x64sc + xscpu64)

Date: 2026-05-02. Branch: `vanilla-cpu-swap`. Triggered by Dragon's Lair v260
investigation, which found that SCPU's IRQ-handler PC distribution diverges
from T65's even though gate vars and dispatch vector are bit-identical.

VICE source cloned at `C:/LLM/C64/vice/vice/src/`. Key files:
- `65816core.c` — 65816 instruction core (xscpu64 uses it)
- `6510core.c` — 6510 core (x64sc uses it)
- `c64/c64cpu.c`, `c64/c64-mem.c` — x64sc CPU/memory
- `scpu64/scpu64cpu.c`, `scpu64/scpu64mem.c` — xscpu64 CPU/memory
- `c64/cart/reu.c` — REU (shared between x64sc and xscpu64)

## Summary

| Topic | VICE behavior | Our behavior | Action |
|---|---|---|---|
| Emu-mode IRQ entry: D flag | `LOCAL_SET_DECIMAL(0)` (`65816core.c:1747`) | v253 preserves D in emu | **Revert v253** to match VICE |
| Emu-mode IRQ entry: PBR | `reg_pbr=0` after vector load (`65816core.c:1753`) | Only cleared for IR=BRK/COP (line 499-503) | **Add IRQ/NMI clear** |
| Emu-mode IRQ: B flag pushed | `LOCAL_SET_BREAK(0)` (`65816core.c:1738`) | Already correct (line 517) | OK |
| Emu-mode IRQ: I flag set | `LOCAL_SET_INTERRUPT(1)` (`65816core.c:1748`) | Already correct (line 434, P(2)<='1') | OK |
| CPU port $00/$01 mirror | `zero_store_mirrored` writes mem_sram + mem_ram (`scpu64mem.c:277`) | vanilla-cpu-swap: bank $00 → main RAM only (no SRAM mirror on this branch) | N/A on this branch |
| REU — atomic vs cycle-stepped | `reu_dma_start` runs whole transfer atomically | `reu.v` matches (atomic on cmd write) | OK |
| 65816 emu vs native mode | `reg_emul` mirrored at `EMULATION_MODE_CHANGED` (`scpu64cpu.c:399`); never forces native | XCE drives EF/MF/XF; no forced switching | OK |

## Detailed findings

### 1. D-flag clear on emu-mode IRQ entry

VICE `65816core.c:1738-1748` (emu-mode IRQ macro):

```c
if (reg_emul) {
    LOCAL_SET_BREAK(0);
    PUSH(reg_pc >> 8); PUSH(reg_pc);
    PUSH(LOCAL_STATUS());
    LOCAL_SET_INTERRUPT(1);
    LOCAL_SET_DECIMAL(0);   /* ← clears D in emu mode too */
    LOAD_INT_ADDR(0xfffe);
}
```

Both x64sc (via 6510core) and xscpu64 (via 65816core) clear D on IRQ entry.
This matches CMOS/W65C816 semantics, NOT NMOS 6502 (which leaves D unchanged).

Our v253 (project_dl_v253_dflag_fix_no_effect.md) preserves D in emu mode
under the rationale "DL was written for stock C64 (NMOS 6510) and may rely
on D staying as-set across IRQs."

**But VICE's x64sc — which renders DL correctly — also clears D**, so the
preservation isn't required for correctness. v253 was a no-op for DL anyway
("Hardware: DL still HEAVILY corrupted, writer pattern IDENTICAL to v252
baseline").

**Action**: revert the `if EF = '0'` guard in P65C816.vhd:435 so D is
cleared in BOTH modes. This brings us in line with VICE.

### 2. PBR clear on emu-mode IRQ vector fetch

VICE `65816core.c:1750-1753`:

```c
LOAD_INT_ADDR(0xfffe);   /* sets reg_pc from $FFFE/$FFFF */
reg_pbr = 0;             /* PBR explicitly zeroed after vector load */
```

Our P65C816.vhd:495-503 (load DKB):

```vhdl
case MC.LOAD_DKB is
    when "01" => D <= AluIntR;
    when "10" =>
        if IR = x"00" or IR = x"02" then  -- BRK/COP reset PBR
            PBR <= (others=>'0');
        else
            PBR <= D_IN;
        end if;
    ...
```

We ONLY clear PBR for software interrupts (`IR=$00` BRK, `IR=$02` COP). For
HARDWARE interrupts (IRQ, NMI), the IR holds the previously-fetched opcode,
so the `else PBR <= D_IN` branch fires — which loads PBR with whatever's
on the data bus during the vector fetch (the PCL byte from $FFFE).

**Latent bug**: this would corrupt PBR when an IRQ/NMI fires in native mode
across banks. In emu mode it doesn't actually trigger DL corruption because:
1. PBR starts at 0 (reset value)
2. DL never sets PBR via JML/JSL across banks
3. Even if PBR gets loaded with garbage, the next opcode fetch is at PBR:PC
   from the vector, and the IRQ vector gives a new PC — so execution goes
   to wherever PBR:vector_target points

But the PBR load is INCORRECT semantically. Real W65C816 always pushes PBR
on the stack and then sets PBR=0 for IRQ/NMI vector fetch.

**Action**: add IRQ/NMI to the PBR-clear branch:

```vhdl
if IR = x"00" or IR = x"02" or IsIRQInterrupt = '1' or IsNMIInterrupt = '1' then
    PBR <= (others=>'0');
else
    PBR <= D_IN;
end if;
```

(Need to verify which microcode state actually loads PBR during IRQ/NMI
entry — the LOAD_DKB="10" path may or may not be on the IRQ entry path.)

### 3. CPU port $00/$01 mirror — N/A on this branch

VICE `scpu64mem.c:243-297`: xscpu64 keeps a "fast" `mem_sram` and a "slow"
`mem_ram`. `zero_store_mirrored` writes BOTH on $00/$01 stores so the
SuperCPU SRAM stays in sync with main RAM.

Our `vanilla-cpu-swap` branch does NOT have a bank-$01 SRAM shadow — that
was added on master (v167, commit edbf1f0). Here:
- bank $00 → C64 main RAM (cart_addr path)
- bank $01+ → SDRAM via `scpu_sdram_addr = {1, bank, addr}` mux at
  c64.sv:1039

Bank $00 zero-page writes go through standard 6510-bus path. There's no
shadow to keep in sync. **No action needed on this branch.**

If we ever port the v167 bank-$01 SRAM shadow back, we'd need to add
write-fanout from bank-$00 ZP $00/$01 stores into the bank-$01 dprom to
match VICE's `zero_store_mirrored`.

### 4. REU — confirmed equivalent

xscpu64's `maincpu_steal_cycles` (`scpu64cpu.c:88-93`) calls `reu_dma_start`
which runs the entire transfer atomically (one shot, not cycle-stepped).
Our `reu.v` matches: cmd write at `$DF01` triggers the FETCH/STASH
state-machine which completes within one CPU instruction window from the
software's POV.

**No action needed.**

### 5. Native vs emu mode handling — confirmed equivalent

xscpu64 never forces native mode; emu/native is purely software-driven via
CLC/SEC + XCE. Same as our P65C816.vhd. **No action needed.**

## v261 implementation plan

Three CPU-core changes:

1. **TSC emu-mode mask** (iigs port): `P65C816.vhd:236` →
   `(x"01" & SP(7 downto 0)) when EF='1' else SP when "101"` (or
   equivalent VHDL conditional in the BUS_CTRL select).

2. **D-flag clear on emu IRQ** (revert v253 partially):
   `P65C816.vhd:435-437` → unconditional `P(3) <= '0'`.

3. **PBR clear on emu IRQ/NMI vector fetch**: `P65C816.vhd:499-503` → add
   `IsIRQInterrupt='1' or IsNMIInterrupt='1'` to the cleared branch.

All three are defensive correctness fixes. They MAY or MAY NOT fix DL —
but since VICE x64sc renders DL correctly with these semantics, aligning
to VICE is a reasonable bet.

## References

- VICE source: `C:/LLM/C64/vice/vice/src/`
- VICE 65816 IRQ macro: `vice/vice/src/65816core.c:1724-1754`
- VICE 6510 IRQ macro: `vice/vice/src/6510core.c:436-475`
- VICE xscpu64 zero store: `vice/vice/src/scpu64/scpu64mem.c:243-297`
- Our P65C816.vhd: `C64_MiSTer/rtl/65C816/P65C816.vhd`
