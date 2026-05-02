# P65C816 — comparison vs `pcornier/iigs_simulation`

Date: 2026-05-02. Branch: `vanilla-cpu-swap`. Triggered by Dragon's Lair
investigation (v260). Reference repo cloned at
`C:/LLM/C64/MiSTerSuperCPU/iigs_simulation/`.

## Summary table

| Topic | iigs (latest) | Ours (P65C816.vhd) | Status |
|---|---|---|---|
| B-flag emu-mode push (IRQ vs BRK/COP) | `EF ? ~GotInterrupt : P[4]` (commit `08479a4`) | `(P(4) or (not GotInterrupt and EF)) and not (GotInterrupt and (IsIRQInterrupt or IsNMIInterrupt) and EF)` (line 517) | **Equivalent** |
| IRQ I-flag mask | At `GotInterrupt` latch (commit `87d68ad`) | At `IRQ_ACTIVE <= not IRQ_N and not P(2)` (line 559) | **Equivalent (earlier in pipeline)** |
| SP emu-mode wrap | Full 16-bit SP, per-opcode tracking for $2B/$6B/$22/$62/$D4/$AB (commit `6a593ab`) | Page-1 normalized: `SP(15:8)<=x"01"` always (lines 347-400) | **Different by design** — ours is more NMOS-correct for C64 emu-mode use |
| Stack ADDR_BUS at 4'b1000 | EF-gated normalization (commit `401ea5e`) | Hard-forced `x"00" & x"01" & SP(7:0)` (line 654) | **Ours is stricter** |
| TSC (BUS_CTRL=101) in emu mode | `EF ? {8'h01, SP[7:0]} : SP` (commit `401ea5e`) | Raw `SP` (line 236) | **Lacks emu-mode mask** — fixed in this branch as v261 |
| Cold-reset CYAREG bit 6 | Sets bit 6 (commit `ba6c163`) | N/A | IIgs-specific (Apple IIgs config register) |

## Detailed notes

### B-flag emu-mode push (line 517)

Both implementations push `B=0` for IRQ/NMI and `B=1` for BRK/COP/PHP when
`EF=1`. Our VHDL form:

```vhdl
((P(4) or (not GotInterrupt and EF))
 and not (GotInterrupt and (IsIRQInterrupt or IsNMIInterrupt) and EF))
```

Truth table for bit 4:
- `EF=0`: P(4) (untouched)
- `EF=1`, `GotInterrupt=0` (BRK/COP/PHP): 1 (forced)
- `EF=1`, `GotInterrupt=1`, IRQ or NMI: 0 (forced)

Matches iigs `EF ? ~GotInterrupt : P[4]` for BRK/COP/IRQ/NMI. The PHP path
goes through the `GotInterrupt=0` branch in both.

### SP emu-mode wrap (lines 347-400)

iigs `6a593ab` ("final processor fixes") removed page-1 normalization in
favour of full 16-bit SP arithmetic with per-opcode tracking sequences for
PLD ($2B), RTL ($6B), JSR-long ($22), PER ($62), PEI ($D4), PLB ($AB).
Their motivation is correctness for IIgs OS routines that use TSC/TCS to
manipulate a 16-bit stack across banks.

We **deliberately keep** page-1 normalization:

```vhdl
SP(15 downto 8) <= x"01";
SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) + 1);
```

C64 software running in emu mode (incl. DL) does NOT use 16-bit SP — it
uses pure 6502 PHA/PHP/PLA/PLP/JSR/RTS, which all wrap within page $01.
Forcing page 1 is more NMOS-faithful for our use case. iigs's 16-bit SP
needs the per-opcode tracking precisely because raw `SP+1` lets SP drift
out of page 1 in sequences where 6502 software expects page-1 wrap.

History: the v158-era `2026-04-20` comment in our code says:

> "match VICE reg_emul=1 stack wrap within page $01. Previously
> unguarded full-16-bit inc caused SP to underflow into zero page in
> emulation mode when opcodes $2B/$6B/$AB (PLD/RTL/PLB) were fetched
> from 6502 unofficial-opcode byte positions, clobbering zp $2F and
> hanging Asterix-class decompressors."

So we already battled this trade-off and settled on page-1 normalization.

### TSC in emu mode (line 236) — **fix landed**

iigs `401ea5e` line 245:

```sv
(MC.BUS_CTRL[5:3] == 3'b101) ? (EF ? {8'h01, SP[7:0]} : SP) : ...
```

Ours (before fix):

```vhdl
SP when "101",
```

When the SP register is read back via the bus driver mux (e.g. for TSC
"transfer SP to C accumulator"), the iigs fix forces high byte = $01 in
emu mode so software reading SP via TSC sees the correct page-1-normalized
value, even if some upstream path leaked a non-$01 high byte into SP.

Defensive correctness fix; doesn't affect Dragon's Lair (DL doesn't use
TSC) but worth porting. **Implemented as v261**: `P65C816.vhd:236` becomes
the EF-gated form.

## What we keep from our local fork

- **v253 D-flag NMOS preservation** (line 425-437): preserves D in emu mode
  during interrupt entry. iigs's interrupt-entry P-write doesn't touch D.
  Note: VICE-comparison (`docs/cpu_vice_emulation_comparison.md`) calls
  this out — VICE actually clears D in BOTH modes, so we should consider
  reverting v253 to match VICE behavior. See VICE doc for resolution.

- **v248 JMP ($xxFF) NMOS page-wrap fix** (line 619): emulation mode
  matches NMOS 6502's page-wrap quirk for JMP indirect with low-byte $FF.
  iigs doesn't have this (Apple IIgs ROM doesn't exercise the quirk).

## References

- iigs commit `08479a4`: `git show 08479a4` in iigs repo
- iigs commit `87d68ad`: `git show 87d68ad`
- iigs commit `6a593ab`: `git show 6a593ab` (292 lines, the big one)
- iigs commit `401ea5e`: `git show 401ea5e`
- Our P65C816.vhd: `C64_MiSTer/rtl/65C816/P65C816.vhd`
