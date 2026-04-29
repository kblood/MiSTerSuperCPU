import sys
path = r'C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\rtl\fpga64_sid_iec.vhd'
with open(path, 'r', encoding='utf-8', newline='') as f:
    text = f.read()

NL = '\r\n'
old = (
    "\t\t\tif pc_c003_hit_r = '1' then" + NL +
    "\t\t\t\tbug_frozen <= '1';" + NL +
    "\t\t\tend if;" + NL +
    NL +
    "\t\t\t-- PRG-load trace reset: on rising edge of bram_invalidate (= start of"
)
new = (
    "\t\t\tif pc_c003_hit_r = '1' then" + NL +
    "\t\t\t\tbug_frozen <= '1';" + NL +
    "\t\t\tend if;" + NL +
    NL +
    "\t\t\t-- 2026-04-26 v129 STP-halt detector via registered IR shadow:" + NL +
    "\t\t\t-- v128 placed this inside the supercpu_en/bug_frozen=0 gate and" + NL +
    "\t\t\t-- never fired on hardware despite I:DB stable. Move to unconditional" + NL +
    "\t\t\t-- region (same as brk_detect_r/pc_c003_hit_r). dbg_ir_d <= dbg_ir_816" + NL +
    "\t\t\t-- is a 1-cycle shadow; after STP halt dbg_ir_d holds DB indefinitely." + NL +
    "\t\t\tdbg_ir_d <= dbg_ir_816;" + NL +
    "\t\t\tif dbg_ir_d = x\"DB\" then" + NL +
    "\t\t\t\tbug_frozen <= '1';" + NL +
    "\t\t\tend if;" + NL +
    NL +
    "\t\t\t-- PRG-load trace reset: on rising edge of bram_invalidate (= start of"
)

print('found:', old in text)
if old not in text:
    sys.exit(1)
text2 = text.replace(old, new, 1)
print('changed:', text != text2)

with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text2)
print('written')
