# LDA Long Crash on MiSTer C64 SuperCPU — Deep Investigation Brief

## Context

I'm adding 65C816 (SuperCPU) support to the MiSTer FPGA C64 core. The 65C816 CPU is from the SNES core (P65C816 entity, VHDL). The system runs at 32 MHz clk32 with the C64 bus arbitration in `fpga64_sid_iec.vhd`. The 65C816 wrapper is `cpu_65c816.vhd`.

There is a reproducible crash where **any 4-byte 65C816 instruction with a bank operand byte fetched from a PC stream** causes a `BRK → KERNAL warm-restart` (screen wipe). This affects:

- `$AF` LDA long (4-byte: opcode + addr16 + bank)
- `$5C` JML long
- `$8F` STA long
- `$CF` CMP long

It does NOT affect:

- 3-byte instructions (`$AD` LDA abs, `$B9` LDA abs,Y)
- 4-byte indirect long (`$A7` LDA `[DP]`) — this loads AB via VDA cycles, not from the PC stream
- 4 NOPs (`$EA $EA $EA $EA`) at the same code position

The crash happens whether the program runs in emulation mode or native 65816 mode. It persists across both my current build (HEAD + a small revert) and an older build (commit 9833fce from April 2). It is **NOT a regression**.

## The $D07A test that surprised me

`$D07A` is a register on the SuperCPU v2 that, when written to, sets the CPU to "software 1MHz" mode. In this codebase, that means:

```vhdl
elsif cpuAddr = x"D07A" then
    scpu_speed_1mhz <= '1';        -- Any write to $D07A = software 1MHz
```

And later:

```vhdl
if supercpu_en = '1' and (scpu_speed_1mhz = '1' or scpu_sys_1mhz = '1' or iec_slow_mode = '1') then
    turbo_en <= '0';
    turbo_m <= "000";
end if;
```

When `turbo_en = '0'`, the BRAM/cache fast path stops contributing to `enableCpu_816`:

```vhdl
enableCpu_816 <= ((bram_hit_d1 and turbo_en and not at_cpucd) or
                  (cache_hit_d1 and turbo_en and not at_cpucd) or
                  (phantom_enable and turbo_en and not at_cpucd) or
                  (enableCpu and not dma_active))
                 when supercpu_en = '1' else '0';
```

So with `$D07A` written, the only path that can advance the CPU is the SDRAM pipeline (`enableCpu`, with no turbo gate). The CPU effectively runs at the native C64 1MHz cycle rate where `cpu_cyc` only fires once per microsecond at the `CYCLE_CPUC` slot.

### Test program sr_slow.s

```asm
.segment "LOADADDR"
.word $0801
.segment "EXEHDR"
.word @next
.word 10
.byte $9E
.byte "2061",0
@next:
.word 0
.segment "CODE"
SCREEN = $0400
BORDER = $D020
SCPU_1MHZ = $D07A
    sei
    lda #$01
    sta BORDER         ; WHITE before LDA long
    lda #$ff
    sta SCPU_1MHZ      ; enable software 1MHz mode (disables turbo)
    clc
    xce
    .a8
    .i8
    sep #$30
    .byte $AF, $20, $D0, $00     ; LDA $00:D020 (the crashing case)
    pha
    lda #$06           ; BLUE if survived
    sta BORDER
loop:
    jmp loop
```

### Expected outcome

If the bug were in the BRAM hit fast path (`bram_hit_d1` returning stale data, page-valid coarseness, BRAM/cache cancel race in `enableCpu` cancellation logic, etc.), then disabling turbo would force everything through the SDRAM pipeline, which has its own well-tested path. The crash should disappear.

### Actual outcome

**The crash persists exactly as before.** The screen wipes, the border resets to KERNAL light blue default, the markers from before LDA long are gone. The `STA $D07A` write does take effect (verified — other tests confirm it controls turbo mode), but the LDA long still crashes.

This is the surprising result I want help understanding.

## What this rules out

1. **BRAM hit fast path** — `bram_hit_d1` doesn't fire because `turbo_en = 0` gates it out of `enableCpu_816`.
2. **Cache hit fast path** — same gate.
3. **Phantom enable fast path** — same gate.
4. **The SDRAM pipeline cancel logic** — there's a known cancellation in the `enableCpu` pipeline:
   ```vhdl
   if (cache_hit_d1 = '1' or bram_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1' then
       cpu_cyc_s <= "00";
       enableCpu <= '0';
       superram_enable_delay <= '0';
       superram_in_pipeline <= '0';
       io_in_pipeline <= '0';
   ```
   This is gated by `turbo_en`, so with turbo off, this cancel never fires. The pipeline runs normally.
5. **Page-valid coarseness for BRAM** — `bram_pgvalid` is per-page; if BRAM had stale data, the SDRAM pipeline path would still bypass BRAM in this configuration.

In short: every BRAM/cache acceleration path is gated by `turbo_en`. With turbo off, the system runs as a plain C64 with SDRAM pipeline as the only data delivery mechanism, and **the crash STILL happens**.

## Architecture details (relevant pieces)

### Bus arbitration

The 32 MHz `clk32` is divided into 32 sub-cycles per 1 microsecond C64 cycle: `EXT0..EXT7`, `DMA0..DMA3`, `VIC0..VIC3`, `CPU0..CPUF`. The CPU normally gets the `CYCLE_CPUC` slot at 1 MHz. In turbo mode it can also use `CPU0/CPU4/CPU8` (extra SDRAM slots).

```vhdl
cpu_cyc <= '1' when
    (sysCycle = CYCLE_CPU0 and turbo_m(0) = '1' and cs_ram = '1' and ...) or
    (sysCycle = CYCLE_CPU4 and turbo_m(1) = '1' and ...) or
    (sysCycle = CYCLE_CPU8 and turbo_m(2) = '1' and ...) or
    (sysCycle = CYCLE_CPUC and (io_enable = '1' or cs_ram = '1')) else '0';
```

With `scpu_speed_1mhz = 1`, `turbo_m = "000"`, so only the CPUC slot fires. Pure 1MHz operation.

### SDRAM pipeline

```vhdl
process(clk32)
begin
    if rising_edge(clk32) then
        if (cache_hit_d1 = '1' or bram_hit_d1 = '1' or phantom_enable = '1') and turbo_en = '1' then
            -- cancel (does NOT fire when turbo_en = 0)
            ...
        else
            cpu_cyc_s <= cpu_cyc_s(0) & (cpu_cyc and not wb_drain_active);
            ...
            if superram_in_pipeline = '1' or io_in_pipeline = '1' then
                superram_enable_delay <= cpu_cyc_s(1);
                enableCpu <= superram_enable_delay;  -- 3-stage pipeline
            else
                superram_enable_delay <= '0';
                enableCpu <= cpu_cyc_s(1);  -- 2-stage pipeline
            end if;
        end if;
    end if;
end process;
```

For bank $00 RAM/ROM and `$F0+` ROM, this is a 2-stage pipeline (`cpu_cyc → cpu_cyc_s(0) → cpu_cyc_s(1) → enableCpu`).

For SuperRAM (banks `$01-$EF`) and IOF reads ($D000-$DFFF I/O), this is a 3-stage pipeline (`cpu_cyc → cpu_cyc_s(0) → cpu_cyc_s(1) → superram_enable_delay → enableCpu`).

### CPU enable

```vhdl
enableCpu_816 <= ((bram_hit_d1 and turbo_en and not at_cpucd) or
                  (cache_hit_d1 and turbo_en and not at_cpucd) or
                  (phantom_enable and turbo_en and not at_cpucd) or
                  (enableCpu and not dma_active))
                 when supercpu_en = '1' else '0';
```

With `turbo_en = 0`, only `(enableCpu and not dma_active)` matters. So the CPU advances exactly once per SDRAM pipeline completion.

### P65C816 instantiation

```vhdl
cpu_816_inst: entity work.cpu_65c816
port map (
    clk => clk32,
    reset => reset or not supercpu_en,
    enable => enableCpu_816,
    ...
    di => cpuDi,
    addr => cpuAddr_816,
    do => cpuDo_816,
    we => cpuWe_816,
    ...
    vpa => vpa_816,
    vda => vda_816,
);
```

The P65C816 is a synchronous design with `CE` (clock enable) controlling whether registers update. When `enable = '0'`, all CPU state freezes. The address bus is combinational from internal registers, so the system sees `cpuAddr_816` change combinationally as soon as registers update on the next clock edge after `enable = '1'`.

### cpuDi mux

```vhdl
cpuDi <= io_data when (iof_detect = '1' and cpuWe_pre = '0') else
         scpu_rom_stub_data when (scpu_rom_stub_active = '1') else
         bram_do  when (bram_hit_d1 = '1') else
         cache_di when (cache_hit_d1 = '1' and scpu_rom_overlay = '0') else
         superram_data_r when (enableCpu = '1' and superram_in_pipeline = '1' and cpuWe_pre = '0') else
         ...
         cpuDi_raw;
```

With turbo off, `bram_hit_d1` and `cache_hit_d1` never fire (well, they do internally but they're gated out of `enableCpu_816`), so `cpuDi` is one of:

- `io_data` for IOF reads ($D000-$DFFF)
- `superram_data_r` for SuperRAM reads
- `cpuDi_raw` from the bus logic (default — bank $00 SDRAM data)

### $AF microcode (LDA long, in MCode.vhd:1597-1602)

```
state 1: [PBR:PC]->AAL, PC++   addrCtrl="01000000" addrBus="0000" loadPC="001" va="01"
state 2: [PBR:PC]->AAH, PC++   addrCtrl="00001000" addrBus="0000" loadPC="001" va="01"
state 3: [PBR:PC]->AB,  PC++   addrCtrl="00000001" addrBus="0000" loadPC="001" va="01"
state 4: [AB:AA+0]->AL         addrCtrl="00000000" addrBus="0101" loadPC="000" va="10" (M=1: LAST_CYCLE)
state 5: [AB:AA+1]->A high     addrBus="0101" va="10" (16-bit M only)
```

`addrCtrl="00000001"` decodes to `AALCtrl="000", AAHCtrl="000", ABSCtrl="01"`. The AddrGen logic for `ABSCtrl = "01"` is simply:

```vhdl
case ABSCtrl is
    when "00" => null;
    when "01" => AB <= D_IN;
    when "10" => AB <= std_logic_vector(unsigned(D_IN) + ("0000000"&NewAAHWithCarry(8)));
    when "11" => 
        if AALCtrl(2) = '0' and AAHCtrl(2) = '0' then
            AB <= std_logic_vector(unsigned(DBR));
        end if;
```

So state 3 just does `AB <= D_IN` synchronously at the next rising edge with `EN = 1`.

`addrBus="0000"` selects `PBR & PC` for the address bus, so during state 3 the system reads from `PBR:PC` (the PC stream — same path as opcode and previous operand bytes).

`addrBus="0101"` for state 4 selects `(AB << 16) + AA + ADDR_INC`, which is the data target.

The address bus is combinational:

```vhdl
process(MC, PC, AA, DX, SP, EF, PBR, DBR, AB, ...)
begin
    case MC.ADDR_BUS is
        when "0000" => ADDR_BUS <= PBR & PC;
        ...
        when "0101"=> ADDR_BUS <= std_logic_vector((unsigned(AB) & x"0000") + ("0000000" & unsigned(AA)) + (x"00" & ADDR_INC));
        ...
    end case;
end process;

A_OUT <= ADDR_BUS;
```

So when state transitions from 3 to 4 at a clock edge:
- `AB ← D_IN` (registered)
- `STATE ← 4` (registered)
- After the edge, the combinational address bus mux switches to `addrBus="0101"` and uses the new `AB` value
- `cpuAddr_816` (= `A_OUT`) reflects `AB:AA` immediately

### NextIR and STATE mechanism

```vhdl
NextIR <= IR when (STATE /= "0000") else
          x"00" when GotInterrupt = '1' else 
          D_IN; 
...
if EN = '1' then
    IR <= NextIR;
    STATE <= NextState;
end if;
```

So `IR` only loads from `D_IN` when `STATE = 0`. The microcode lookup uses `NextIR` and `NextState`:

```vhdl
MCodeInst: entity work.MCode 
port map (
    IR => NextIR,
    STATE => NextState,
    M => MC
);
```

Inside MCode, `MI` is a registered output:

```vhdl
elsif rising_edge(CLK) then
    STATE2 := STATE - 1;
    if EN = '1' then
        if STATE = "0000" then
            MI <= ("000","0000","00","000","00","00","00000000","001","000","000","00","000000","00000","00","000","11");
        else
            MI <= M_TAB(to_integer(unsigned(IR) & STATE2(2 downto 0)));
        end if;
    end if;
```

`MI` (and thus `MC` in P65C816) is the registered micro-op currently being executed.

## What I want help understanding

Given that **the crash persists with turbo off**, the bug must be in the SDRAM-pipeline-only path. Specifically:

1. The CPU runs at 1 MHz, advancing once per `CYCLE_CPUC` SDRAM read.
2. Each instruction byte fetch takes about 32 clk32 cycles (1 microsecond).
3. For LDA long: 1 opcode fetch + 3 operand fetches + 1 data fetch = 5 microseconds.
4. After the 4-byte LDA long completes, the CPU should fetch the next opcode (PHA in my test) at PC = `instr_addr + 4`.

What could cause $AF specifically to crash where $AD (3-byte LDA abs) does not, and where 4 NOPs ($EA $EA $EA $EA) at the same position do not?

### Hypotheses I've considered

**(A) Microcode encoding bug.** I read the microcode for $AF carefully. State 1, 2, 3 all do `[PBR:PC]->X, PC++` with `addrBus="0000"`, `loadPC="001"`, `va="01"`. State 1 captures D_IN to AAL, state 2 to AAH, state 3 to AB. They look symmetric and correct. Why would state 3 fail when states 1 and 2 succeed?

**(B) PC off-by-one after $AF.** Could $AF leave PC pointing at the bank operand byte instead of the next opcode? With bank operand `$00`, fetching that byte = BRK, which triggers the warm-restart. But this contradicts: with bank operand `$01` (sr_b01.s), the test WORKS. With bank operand `$01` in a different position (sr_b1.s), it CRASHES. The PC-off-by-one theory predicts both should behave the same. So either this is wrong, or PC-off-by-one only happens conditionally.

**(C) D_IN sampling race.** What if the system delivers `D_IN = $00` to the CPU at the moment state 3 captures? Then `AB <= $00` always, regardless of the actual operand. But the operand byte at PC+3 in my test is `$00` (because the bank operand IS `$00`), so this would be silently correct in the `bank=$00` case and noticeably wrong in the `bank=$01/$02` cases. Yet the `bank=$01` cases sometimes work and sometimes don't. So this doesn't quite fit either.

**(D) Pipeline race in state 3 → state 4 transition.** When state 3 captures D_IN to AB on a rising edge, the next cycle the address bus combinationally jumps to `AB:AA`. If the system reads this new address before AB has actually settled into the registered state, it might get a wrong address. But P65C816 is fully synchronous and AB is registered, so this shouldn't happen.

**(E) `localDi <= localDo when localWe = '0'` in the wrapper.** The `cpu_65c816.vhd` wrapper has this odd line:
```vhdl
localDi <= localDo when localWe = '0'
            else std_logic_vector(di) when accessIO = '0'
            else ioDir when localA(0) = '0'
            else currentIO;
```
When the CPU is writing (`localWe = '0'`, active low), `localDi` reflects the CPU's own output. This is unusual. For LDA long state 4 (a read), `localWe = '1'`, so `localDi = di`. For STA long ($8F), state 4 IS a write, so `localDi = localDo` (the data being written). Both crash, so this isn't the difference.

But could there be an unexpected glitch in `localWe` during the state transition where `localWe` momentarily goes low, causing `localDi` to be overridden with `localDo` instead of `di` at the wrong moment? Hmm.

**(F) Microcode lookup for the FIRST cycle of next instruction.** When LDA long ends and the next opcode is fetched, `STATE = 0` for one cycle, and during that cycle the init MI is loaded (`addrBus="0000", loadPC="001", va="11"`). Then on the next edge, `IR ← NextIR = D_IN` (the next opcode). MI gets the row 0 of the new opcode's microcode. Could this transition somehow load the wrong micro-op for $AF specifically?

## What I want from you

Given:
- The bug is real and reproducible
- Turbo OFF (1 MHz mode) doesn't fix it, so it's not in BRAM/cache acceleration paths
- It's specific to 4-byte instructions with bank operand from PC stream ($AF, $5C, $8F, $CF)
- Microcode encoding looks correct on inspection
- It happens in both emulation and native modes
- It happens regardless of target memory type (RAM, I/O, SuperRAM)

**What's the most plausible root cause?** 

Possible angles to investigate:
1. Is there a known P65C816 bug from the SNES core that affects 4-byte long instructions?
2. Is there something about the `ABSCtrl="01"` AB load that might race with the `addrBus="0101"` mux selection in the next cycle?
3. Is there a way the `localWe` signal could glitch during state transitions in a way that affects D_IN sampling?
4. Could the `MCode` MI register have a one-cycle skew between `NextIR/NextState` driving lookup and the actual `MI` output that causes the address bus to use the wrong micro-op for one cycle?
5. Are there signal name conventions in the SNES P65C816 implementation (`ABSCtrl`, `addrBus="0101"`, `va="01"` for VPA, `va="10"` for VDA) that have known issues?
6. What's the canonical 65816 cycle count for LDA long, STA long, JML long, and CMP long? Could the wrapper be off by a cycle for these specifically?
7. Is there documented behavior for the bus signals during the bank fetch cycle (state 3 of LDA long) that might be implemented incorrectly here?

The P65C816 source files are:
- `MCode.vhd` — microcode table (2048 entries, indexed by IR & STATE)
- `AddrGen.vhd` — address generator (AAL, AAH, AB, DX registers)
- `P65C816.vhd` — top-level state machine, address bus mux, register file
- `P65816_pkg.vhd` — type definitions (MicroInst_r record)
- `cpu_65c816.vhd` — C64-side wrapper (adds I/O port at $0000-$0001)

This is from the SNES MiSTer core, lightly modified for SuperCPU integration.
