# VICE source map for C64 / SuperCPU boot research

This is a curated map of the most relevant VICE source files for our current
question: *what is the minimum machine behavior needed to reach BASIC `READY.`?*

## Machine bring-up

### `vice/src/c64/c64.c`
Why it matters:
- main C64 machine init order
- shows which components VICE considers essential before runtime

Notable lines from current mirror:
- around `1078-1088`: VIC-II init, `c64_mem_init()`, `cia1_init()`, `cia2_init()`, `c64keyboard_init()`
- around `1123-1129`: keyboard buffer init and C64-specific I/O init

Question it helps answer:
- what is the earliest machine subset that must exist before boot proceeds?

### `vice/src/scpu64/scpu64.c`
Why it matters:
- SuperCPU machine bring-up
- shows how VICE sequences SCPU memory, CIAs, keyboard, glue, IEC

Notable lines from current mirror:
- around `844-854`: VIC-II init -> `scpu64_mem_init()` -> `cia1_init()` -> `cia2_init()` -> `c64keyboard_init()`
- around `926-966`: reset vs power-up split
- around `913-916`: IEC / fast IEC / cartridge later in init

Question it helps answer:
- how much of the SuperCPU environment is boot-critical vs later/optional?

## CIA behavior

### `vice/src/c64/c64cia1.c`
Why it matters:
- actual C64 keyboard-matrix-facing CIA1 behavior
- shows that CIA1 is much more than a constant `$FF` read device
- demonstrates DDR/port interaction and matrix scanning logic

Notable lines from current mirror:
- `286-341`: `read_ciapa()`
- `365-433`: `read_ciapb()`
- `466-515`: CIA1 context setup hooks

Question it helps answer:
- what minimum port semantics must our reduced CIA model implement?

### `vice/src/c64/c64cia2.c`
Why it matters:
- CIA2 behavior for VIC banking / IEC-related interactions
- likely relevant to display startup and bank selection assumptions

Question it helps answer:
- how realistic does CIA2 need to be for first text-screen activity?

### `vice/src/core/ciacore.c`
Why it matters:
- common MOS6526 implementation used by VICE
- timer, interrupt, register, and sequencing behavior

Question it helps answer:
- do we need full timer/IRQ semantics for a boot-capable harness, or only a subset?

### `vice/src/core/ciatimer.c`
### `vice/doc/CIA-README.txt`
Why they matter:
- explain VICE’s CIA timer model and what parts are performance shortcuts vs real semantics
- useful when deciding whether our harness needs real CIA timing or just believable register behavior

Question they help answer:
- are timers a likely first-order blocker for cold boot?

## Memory initialization

### `vice/src/c64/c64meminit.c`
Why it matters:
- canonical C64 memory map table setup
- shows how VICE wires I/O, ROM, color RAM, CIA1 (`$DCxx`), CIA2 (`$DDxx`)

Notable lines from current mirror:
- `166-212`: I/O page setup including CIA1/CIA2 hooks
- `214+`: Kernal ROM mapping setup

Question it helps answer:
- is our reduced harness exposing the same fundamental boot-time visibility?

### `vice/src/scpu64/scpu64meminit.c`
Why it matters:
- SuperCPU memory map and boot/ROM/IO mapping distinctions
- particularly useful for comparing MiSTer SuperCPU bank visibility questions

Notable lines from current mirror:
- `45-52`: config bits including boot/dos/hw/game/exrom/loram/hiram/charen
- `260+`: memory dispatch table setup

Question it helps answer:
- what parts of SuperCPU mapping are likely essential just to start correctly?

### `vice/src/scpu64/scpu64mem.c`
Why it matters:
- SuperCPU memory implementation and power-up behavior

Notable lines from current mirror:
- around `1455-1461`: `mem_powerup()` initializes RAM/SRAM/trap RAM and VIC color RAM

Question it helps answer:
- are we missing power-up initialization that the ROM expects before writing the screen?

## Keyboard / input

### `vice/src/c64/c64keyboard.c`
### `vice/src/c64/c64keyboard.h`
Why they matter:
- keyboard matrix behavior and restore-key support

Question they help answer:
- what is the minimum stable “no key pressed” behavior the ROM expects?

## How to use this map

Prioritize reading in this order:
1. `scpu64/scpu64.c`
2. `c64/c64.c`
3. `c64/c64cia1.c`
4. `c64/c64cia2.c`
5. `c64/c64meminit.c`
6. `scpu64/scpu64meminit.c`
7. `core/ciacore.c` and `doc/CIA-README.txt`

That order should answer most of the boot-minimum questions before we make the
next expensive RTL rebuild.
