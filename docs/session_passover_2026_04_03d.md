F:56C2 = 22,210 frames = ~370 seconds (~6.2 minutes) — NO CRASH!

  The previous crash was at F:15DF (~5,599 frames, ~93s) or F:37E6 (~14,310 frames, ~238s with cache improvements). We've now passed F:56C2 (~22,210 frames) with completely stable execution:
  - K:2C constant (PBR never left game code bank)
  - S:01FD constant (stack stable)
  - I:5C constant (JML game loop)
  - E:0 constant (native mode)

  The pre-registered SuperRAM address in clk64 fixes the SDRAM timing violation! Let me take a screenshot to see Doom's state:

● Bash(python "C:\LLM\C64\MiSTerSuperCPU\tools\mister_debug.py" screen screenshot_doom_6min.png 2>&1)
  ⎿  Taking screenshot...
     Retrieving /media/fat/screenshots/C64/20260404_000815-screen.png...
     Screenshot saved to screenshot_doom_6min.png
  ⎿  (timeout 15s)

  Read 1 file (ctrl+o to expand)

● Doom is running stably past 6+ minutes with no crash. The pre-registered SuperRAM address fix eliminates the SDRAM timing violation. The game is in a polling loop (expected — the VIC IRQ handling needs        
  separate work), but critically, no BRK/$00 crash from SDRAM.

  Let me update the project memory and then keep monitoring even longer to confirm stability:

  Read 1 file, listed 1 directory, recalled 2 memories, wrote 3 memories (ctrl+o to expand)

● Now update the Doom crash analysis memory:

  Recalled 1 memory, wrote 1 memory (ctrl+o to expand)

● Update MEMORY.md with the fix status:

  Wrote 1 memory (ctrl+o to expand)

● Now let me also update the Doom status section:

  Wrote 1 memory (ctrl+o to expand)

● Now let me take a final screenshot and write a session passover document:

● Bash(python "C:\LLM\C64\MiSTerSuperCPU\tools\mister_debug.py" uart 3 2>&1 | head -5)
  ⎿  Reading debug UART for 3s...
     A:0E0C K:2C B:00 S:01FD P:04 I:5C E:0 F:74AD T:01 C:4895 N:3FC5
     A:0E0C K:2C B:00 S:01FD P:04 I:5C E:0 F:74AE T:01 C:4895 N:3FC5
     … +2 lines (ctrl+o to expand)
  ⎿  (timeout 15s)

● F:74AD = 29,869 frames = ~10 minutes of stable execution. The crash fix is confirmed.

  Here's a summary of what was accomplished:

  Session Results

  SDRAM timing crash FIXED — Doom no longer crashes after ~180s of SuperRAM execution.

  The Fix

  Pre-register supercpu_bank and dbg_cpu_addr in the clk64 domain in c64.sv:
  reg [7:0]  supercpu_bank_r64;
  reg [15:0] dbg_cpu_addr_r64;
  always @(posedge clk64) begin
      supercpu_bank_r64 <= supercpu_bank;
      dbg_cpu_addr_r64  <= dbg_cpu_addr;
  end
  wire [24:0] scpu_superram_addr = {1'b1, supercpu_bank_r64, dbg_cpu_addr_r64};

  This eliminates the -15ns clk32→clk64 timing violation on the SuperRAM address path. The 1-clk64 latency is safe because the CPU address is stable for 6+ clk64 cycles between CPUC and enableCpu.

  What Failed

  Modifying sdram.v to delay the ACTIVE command (sram_pending approach) caused boot failure — the additional combinational logic in the CE detection path changed fitter placement enough to corrupt bank $00      
  reads.

  Remaining Issue

  Doom runs stably but is stuck in a polling loop (I:5C = JML, T:01 = 1MHz). It's waiting for a VIC IRQ/vsync interrupt that never fires because Doom's init code disables interrupts. The next step is
  investigating how Doom expects to receive the vsync signal for game progression.
  
  The next step for getting Doom fully playable is investigating why it's stuck in the polling loop (I:5C JML, T:01 1MHz) — it needs a VIC IRQ/vsync mechanism that isn't currently firing. But the critical SDRAM   timing crash is resolved.