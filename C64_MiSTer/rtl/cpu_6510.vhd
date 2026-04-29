-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- 6510 wrapper — vanilla port shape, P65C816 (emulation mode) inside.
-- Adds 8 bit I/O port mapped at addresses $0000 to $0001.
--
-- This adapter exists so the rest of fpga64_sid_iec.vhd stays at vanilla
-- while the CPU underneath is the 65C816. After RST_N rises the 65C816
-- powers up in emulation mode (E=1, M=X=1) where its instruction set
-- matches the NMOS 6502 closely enough to run the C64 KERNAL/BASIC.
--
-- nmi_ack: P65C816 doesn't export a "vector pulled" signal. The cartridge
-- module uses nmi_ack to detect freeze; without a cartridge this is
-- benign, so we tie it low. Future work: edge-detect $FFFA/B fetch via
-- VPB if a cart needs it.
--
-- -----------------------------------------------------------------------

library IEEE;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

-- -----------------------------------------------------------------------

entity cpu_6510 is
	port (
		clk     : in  std_logic;
		enable  : in  std_logic;
		reset   : in  std_logic;
		nmi_n   : in  std_logic;
		nmi_ack : out std_logic;
		irq_n   : in  std_logic;
		rdy     : in  std_logic;

		di      : in  unsigned(7 downto 0);
		do      : out unsigned(7 downto 0);
		addr    : out unsigned(15 downto 0);
		we      : out std_logic;

		diIO    : in  unsigned(7 downto 0);
		doIO    : out unsigned(7 downto 0)
	);
end cpu_6510;

-- -----------------------------------------------------------------------

architecture rtl of cpu_6510 is
	signal localA  : std_logic_vector(23 downto 0);
	signal localDi : std_logic_vector(7 downto 0);
	signal localDo : std_logic_vector(7 downto 0);
	signal localWe : std_logic;  -- active-low, matches T65/P65C816 WE convention

	signal currentIO : std_logic_vector(7 downto 0);
	signal ioDir     : std_logic_vector(7 downto 0);
	signal ioData    : std_logic_vector(7 downto 0);

	signal accessIO : std_logic;

	signal rdy_gated : std_logic;  -- RDY only halts on reads (6502 semantic)
begin

	-- Real 6502 RDY semantic: RDY=0 halts the CPU only on READ cycles;
	-- WRITE cycles complete regardless of RDY. T65 implements this
	-- internally. P65C816's `EN <= RDY_IN AND CE …` halts on every cycle,
	-- which corrupts the bus during VIC-II badline write-stalls.  Replicate
	-- the 6502 semantic externally by forcing RDY_IN=1 on write cycles
	-- (localWe='0' = write per P65C816 convention).
	rdy_gated <= rdy or not localWe;

	cpu : entity work.P65C816
	port map (
		CLK     => clk,
		RST_N   => not reset,
		CE      => enable,
		RDY_IN  => rdy_gated,
		NMI_N   => nmi_n,
		IRQ_N   => irq_n,
		ABORT_N => '1',
		D_IN    => localDi,
		D_OUT   => localDo,
		A_OUT   => localA,
		WE      => localWe
		-- RDY_OUT, VPA, VDA, MLB, VPB, EF_OUT, DBG_* left unconnected
	);

	-- 6510 IO port detect: addresses $0000 (DDR) and $0001 (data)
	accessIO <= '1' when localA(15 downto 1) = X"000"&"000" else '0';

	-- CPU-side data-in mux (matches vanilla cpu_6510.vhd):
	--   write cycle      : feed back localDo (T65 convention; load-bearing on
	--                       P65C816 too — verified 2026-04-29: removing it
	--                       made the boot banner show '7' chars row from
	--                       leaked $0001 IO-port reads bleeding into screen
	--                       writes)
	--   normal read      : forward system di
	--   IO port read $0000 : ioDir
	--   IO port read $0001 : currentIO
	localDi <= localDo                  when localWe = '0' else
	           std_logic_vector(di)     when accessIO = '0' else
	           ioDir                    when localA(0) = '0' else
	           currentIO;

	process(clk)
	begin
		if rising_edge(clk) then
			if accessIO = '1' then
				if localWe = '0' and enable = '1' then
					if localA(0) = '0' then
						ioDir  <= localDo;
					else
						ioData <= localDo;
					end if;
				end if;
			end if;

			currentIO <= (ioData and ioDir) or (std_logic_vector(diIO) and not ioDir);

			if reset = '1' then
				ioDir     <= (others => '0');
				ioData    <= (others => '1');
				currentIO <= "00111111";  -- KERNAL writes $37 to $0001 expects this default
			end if;
		end if;
	end process;

	-- External wires
	addr    <= unsigned(localA(15 downto 0));
	do      <= unsigned(localDo);
	we      <= not localWe;
	doIO    <= unsigned(currentIO);
	nmi_ack <= '0';  -- P65C816 lacks a vector-pulled signal; cartridge freeze unsupported on this baseline
end architecture;
