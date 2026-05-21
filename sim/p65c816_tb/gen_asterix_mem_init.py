#!/usr/bin/env python3
"""Generate VHDL memory-initialization code from asterix.prg.

Reads asterix.prg (PRG format: 2-byte load address + payload), produces
a .vhd snippet that can be inserted into a testbench init_mem function.
Also populates $FFFC (reset vector) -> $0820.

Output: sim/p65c816_tb/asterix_mem_init.vhd  (just the process body)
"""
from pathlib import Path

def main():
    prg = Path(__file__).parent.parent.parent / 'asterix.prg'
    out = Path(__file__).parent / 'asterix_mem_init.vhd'
    data = prg.read_bytes()
    load_addr = data[0] | (data[1] << 8)
    payload = data[2:]
    print(f"Load addr: ${load_addr:04X}, payload: {len(payload)} bytes")
    lines = []
    lines.append('        -- Reset vector -> $0820 (phase-1 entry)')
    lines.append('        m(16#FFFC#) := x"20"; m(16#FFFD#) := x"08";')
    lines.append('        m(16#FFFE#) := x"00"; m(16#FFFF#) := x"FF";')
    lines.append('        m(16#FF00#) := x"40";  -- RTI')
    lines.append('')
    lines.append('        -- KERNAL/BASIC stubs to avoid traps:')
    lines.append('        m(16#E5A0#) := x"60";  -- RTS')
    lines.append('        m(16#A659#) := x"60";  -- RTS')
    lines.append('')
    lines.append('        -- Asterix PRG payload loaded at $0801 onwards')
    # Group bytes in 8-per-line for readability
    end = load_addr + len(payload)
    for addr in range(load_addr, min(end, 0x10000)):
        b = payload[addr - load_addr]
        lines.append(f'        m(16#{addr:04X}#) := x"{b:02X}";')
    out.write_text('\n'.join(lines) + '\n')
    print(f"Wrote {out} ({len(lines)} lines)")

if __name__ == '__main__':
    main()
