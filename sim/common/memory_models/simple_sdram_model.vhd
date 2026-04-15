-- simple_sdram_model.vhd
--
-- Behavioral SDRAM backing store for Phase 3/4 harnesses.
--
-- Not a cycle-accurate SDRAM chip model. It models the software-visible
-- semantics relevant to the SuperCPU PRG-load bug class:
--
--   * 24-bit address space (16 MB), enough for bank $00 RAM + SuperRAM +
--     the REU region at 0x1000000.
--   * 2-stage read latency for "bank $00" region (banks $00 / $F0-$FF ROM).
--   * 3-stage read latency for "SuperRAM" region (bank $01+).
--   * Byte-wide writes take effect on the cycle they are presented.
--   * Deterministic initial content: all bytes = 0x00.
--
-- The pipeline depths are chosen to match the real fpga64_sid_iec.vhd
-- comment block at ~line 385:
--
--   "SuperRAM 3-stage pipeline: extra delay for turbo slot SDRAM reads.
--    VIC0 SDRAM data clobbers dout_r before 2-stage enableCpu fires.
--    Adding 1 extra cycle gives the SDRAM read more time to complete."
--
-- Interface:
--   clk    : free-running simulation clock
--   reset  : synchronous clear
--   addr   : 24-bit byte address (bank << 16 | offset16)
--   din    : 8-bit write data
--   we     : write strobe (synchronous)
--   re     : read strobe (synchronous) — the read pipeline only advances
--            when re='1' on the input cycle
--   dout   : 8-bit read data, valid N cycles after re (N=2 for bank $00,
--            N=3 for bank $01+)
--
-- Notes:
--   * This model is intentionally pessimistic about depth — you get the
--     full 3-stage delay for any bank > 0.
--   * If the harness needs to initialize non-zero content (e.g., KERNAL
--     ROM), use the `preload_byte` sim-only procedure exposed via the
--     wrapper's shared variable interface.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity simple_sdram_model is
    generic (
        -- Total usable size in bytes. Default = 2 MiB, enough for bank
        -- $00 + a handful of SuperRAM banks. Increase for REU tests.
        MEM_BYTES : integer := 2 * 1024 * 1024
    );
    port (
        clk   : in  std_logic;
        reset : in  std_logic;

        -- 24-bit address; only the low MEM_BYTES'worth of bits is used.
        addr  : in  unsigned(23 downto 0);
        din   : in  std_logic_vector(7 downto 0);
        we    : in  std_logic;
        re    : in  std_logic;
        dout  : out std_logic_vector(7 downto 0);

        -- Debug probe: dump a byte combinationally (used by the scoreboard)
        probe_addr : in  unsigned(23 downto 0);
        probe_dout : out std_logic_vector(7 downto 0)
    );
end entity;

architecture beh of simple_sdram_model is

    type mem_t is array (0 to MEM_BYTES-1) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));

    -- Pipeline stages for read latency
    signal rd_stage1 : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_stage2 : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_stage3 : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_valid1 : std_logic := '0';
    signal rd_valid2 : std_logic := '0';
    signal rd_valid3 : std_logic := '0';
    signal rd_is_superram : std_logic := '0';
    signal rd_is_superram_2 : std_logic := '0';
    signal rd_is_superram_3 : std_logic := '0';

    function safe_idx(a : unsigned(23 downto 0)) return integer is
        variable i : integer;
    begin
        i := to_integer(a);
        if i >= MEM_BYTES then
            return 0;
        else
            return i;
        end if;
    end function;

begin

    ------------------------------------------------------------------
    -- Synchronous memory process
    ------------------------------------------------------------------
    sdram_proc : process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                rd_valid1 <= '0';
                rd_valid2 <= '0';
                rd_valid3 <= '0';
                rd_stage1 <= (others => '0');
                rd_stage2 <= (others => '0');
                rd_stage3 <= (others => '0');
                rd_is_superram   <= '0';
                rd_is_superram_2 <= '0';
                rd_is_superram_3 <= '0';
            else
                -- Write path: byte write, combinational enable, effect at clock edge.
                if we = '1' then
                    idx := safe_idx(addr);
                    mem(idx) := din;
                end if;

                -- Read pipeline stage 1: sample at re='1'
                if re = '1' then
                    idx := safe_idx(addr);
                    rd_stage1 <= mem(idx);
                    rd_valid1 <= '1';
                    -- SuperRAM region = any bank except $00. (The real system
                    -- also routes $F0-$FF ROM reads through the 2-stage path,
                    -- but for this harness the 3-stage is a superset and
                    -- safe.)
                    if addr(23 downto 16) /= x"00" then
                        rd_is_superram <= '1';
                    else
                        rd_is_superram <= '0';
                    end if;
                else
                    rd_valid1 <= '0';
                    rd_is_superram <= '0';
                end if;

                -- Stage 2: always propagate
                rd_stage2 <= rd_stage1;
                rd_valid2 <= rd_valid1;
                rd_is_superram_2 <= rd_is_superram;

                -- Stage 3: always propagate
                rd_stage3 <= rd_stage2;
                rd_valid3 <= rd_valid2;
                rd_is_superram_3 <= rd_is_superram_2;
            end if;
        end if;
    end process;

    -- Output mux: bank $00 = 2 stages (rd_stage2), SuperRAM = 3 stages (rd_stage3)
    -- Note: in practice the harness samples dout when it knows the read's
    -- depth, but we expose the longer one by default for correctness over
    -- SuperRAM reads.
    dout <= rd_stage3 when rd_is_superram_3 = '1' else rd_stage2;

    -- Combinational probe: used by the scoreboard to read memory directly,
    -- bypassing the pipeline. This is sim-only and does not exist in real HW.
    probe_dout <= mem(safe_idx(probe_addr));

end architecture;
