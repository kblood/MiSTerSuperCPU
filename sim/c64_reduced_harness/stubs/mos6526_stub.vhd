-- mos6526_stub.vhd
--
-- Phase 4b: behavioral VHDL stub matching the interface of the Verilog
-- mos6526.v module that fpga64_sid_iec.vhd instantiates as a component.
--
-- Port list is reproduced EXACTLY from the `component mos6526` block in
-- C64_MiSTer/rtl/fpga64_sid_iec.vhd lines 639-666. GHDL binds the VHDL
-- entity to the component declaration by name.
--
-- This stub is intentionally minimal:
--   * All outputs drive deterministic quiescent values.
--   * db_out returns $FF on reads (open-bus-like).
--   * IRQ output stays high (inactive, active-low).
--   * pa_out / pb_out / pa_oe / pb_oe default to $00 (tristate off).
--   * sp_out / cnt_out / pc_n stay high.
--
-- This is enough to let BASIC + KERNAL reset-boot to the READY prompt
-- without being blocked by keyboard-matrix reads (CIA1) or IEC/VIC bank
-- register reads (CIA2). CIA1/CIA2 read pathways return $FF which matches
-- "no keys pressed / no IEC activity" for the 6510 reset sequence.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mos6526 is
    port (
        clk           : in  std_logic;
        mode          : in  std_logic := '0';
        phi2_p        : in  std_logic;
        phi2_n        : in  std_logic;
        res_n         : in  std_logic;
        cs_n          : in  std_logic;
        rw            : in  std_logic;
        rs            : in  unsigned(3 downto 0);
        db_in         : in  unsigned(7 downto 0);
        db_out        : out unsigned(7 downto 0);
        pa_in         : in  unsigned(7 downto 0);
        pa_out        : out unsigned(7 downto 0);
        pa_oe         : out unsigned(7 downto 0);
        pb_in         : in  unsigned(7 downto 0);
        pb_out        : out unsigned(7 downto 0);
        pb_oe         : out unsigned(7 downto 0);
        flag_n        : in  std_logic;
        pc_n          : out std_logic;
        tod           : in  std_logic;
        sp_in         : in  std_logic;
        sp_out        : out std_logic;
        cnt_in        : in  std_logic;
        cnt_out       : out std_logic;
        irq_n         : out std_logic;
        -- Debug taps added by UART-instrumentation work (2026-05); the real
        -- mos6526.v exposes these and fpga64_sid_iec.vhd associates them.
        dbg_imr       : out std_logic_vector(4 downto 0);
        dbg_cra       : out std_logic_vector(7 downto 0);
        dbg_pra       : out std_logic_vector(7 downto 0);
        dbg_prb       : out std_logic_vector(7 downto 0);
        dbg_ddra      : out std_logic_vector(7 downto 0);
        dbg_ddrb      : out std_logic_vector(7 downto 0);
        dbg_timer_a       : out std_logic_vector(15 downto 0);
        dbg_timer_a_latch : out std_logic_vector(15 downto 0);
        dbg_icr           : out std_logic_vector(4 downto 0)
    );
end entity;

architecture stub of mos6526 is
begin

    -- All reads return $FF. This models "no keys pressed" for CIA1 keyboard
    -- scan and "no IEC activity" for CIA2. The real 6510 KERNAL reset handler
    -- copes with these values and proceeds into BASIC cold-start.
    db_out  <= x"FF";

    -- Output data-direction / port registers all quiescent.
    pa_out  <= (others => '0');
    pa_oe   <= (others => '0');
    pb_out  <= (others => '0');
    pb_oe   <= (others => '0');

    -- Interrupts inactive (active-low).
    irq_n   <= '1';

    -- Serial lines inactive.
    pc_n    <= '1';
    sp_out  <= '1';
    cnt_out <= '1';

    -- Debug taps: quiescent (this stub has no internal CIA state).
    dbg_imr           <= (others => '0');
    dbg_cra           <= (others => '0');
    dbg_pra           <= (others => '0');
    dbg_prb           <= (others => '0');
    dbg_ddra          <= (others => '0');
    dbg_ddrb          <= (others => '0');
    dbg_timer_a       <= (others => '0');
    dbg_timer_a_latch <= (others => '0');
    dbg_icr           <= (others => '0');

end architecture;
