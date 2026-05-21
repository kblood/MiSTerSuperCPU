# STP-detection trigger draft (for $8A00 hang investigation)

After cache_disable_r build closes timing and is deployed, add this trigger
near the existing C003 freeze logic in fpga64_sid_iec.vhd around line 3053:

```vhdl
-- 2026-04-25 night: $8A00 STP-halt trigger.
-- Asterix progresses past C003 with Fix A but hits a deterministic STP at
-- A:$8A00 / I:$DB. PC is misrouted to $89FF where data byte $DB lives.
-- Freeze on first IR=$DB to capture the 128 PCs leading up to STP.
if enableCpu_816 = '1' and dbg_ir_816 = x"DB" and dbg_pbr_816 = x"00" then
    bug_frozen <= '1';
end if;
```

Place AFTER pc_c003_hit_r logic but BEFORE seen_bank_2d / dispatcher triggers
to ensure freeze happens on the FIRST STP, not after dispatcher loops.

After deploy:
1. `tools/mister_debug.py uart 5` → confirm fresh boot stream
2. Load asterix.mgl
3. UART will emit ~199 TR lines after freeze fires; collect via `uart 30`
4. Decode TR ring: should show JMP/RTS source that landed PC at $89FF
