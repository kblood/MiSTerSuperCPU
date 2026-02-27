-- -----------------------------------------------------------------------
--
-- cpu_65c816 - 65C816 wrapper for C64 SuperCPU integration
--
-- Presents a cpu_6510-compatible interface around the P65C816 core
-- (from the SNES MiSTer core). Adds the 6510 I/O port at $0000-$0001
-- and exposes bank_addr and emulation_mode for the system.
--
-- -----------------------------------------------------------------------

library IEEE;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

-- -----------------------------------------------------------------------

entity cpu_65c816 is
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
		doIO    : out unsigned(7 downto 0);

		-- 65C816-specific outputs
		addr_hi       : out unsigned(7 downto 0);  -- bank byte (A16-A23)
		emulation_mode: out std_logic;              -- '1' = 6502 emulation mode
		vpa           : out std_logic;              -- Valid Program Address
		vda           : out std_logic;               -- Valid Data Address

		-- Debug outputs
		dbg_sp        : out unsigned(15 downto 0);
		dbg_p         : out unsigned(7 downto 0);
		dbg_ir        : out unsigned(7 downto 0)
	);
end cpu_65c816;

-- -----------------------------------------------------------------------

architecture rtl of cpu_65c816 is
	signal localA     : std_logic_vector(23 downto 0);
	signal localDi    : std_logic_vector(7 downto 0);
	signal localDo    : std_logic_vector(7 downto 0);
	signal localWe    : std_logic;  -- active low (R/W#), same as T65
	signal localEF    : std_logic;
	signal localVPB   : std_logic;
	signal localSP    : std_logic_vector(15 downto 0);
	signal localP     : std_logic_vector(7 downto 0);
	signal localIR    : std_logic_vector(7 downto 0);

	signal currentIO  : std_logic_vector(7 downto 0);
	signal ioDir      : std_logic_vector(7 downto 0);
	signal ioData     : std_logic_vector(7 downto 0);

	signal accessIO   : std_logic;

	-- NMI edge detection for nmi_ack generation
	signal nmi_n_prev : std_logic := '1';
	signal nmi_active : std_logic := '0';
begin

	cpu: entity work.P65C816
	port map(
		CLK     => clk,
		RST_N   => not reset,
		CE      => enable,
		RDY_IN  => rdy,
		NMI_N   => nmi_n,
		IRQ_N   => irq_n,
		ABORT_N => '1',
		D_IN    => localDi,
		D_OUT   => localDo,
		A_OUT   => localA,
		WE      => localWe,
		RDY_OUT => open,
		VPA     => vpa,
		VDA     => vda,
		MLB     => open,
		VPB     => localVPB,
		EF_OUT  => localEF,
		DBG_SP  => localSP,
		DBG_P   => localP,
		DBG_IR  => localIR
	);

	-- 6510 I/O port at $0000-$0001 (active only in bank $00)
	accessIO <= '1' when localA(23 downto 1) = "00000000000000000000000" else '0';
	localDi  <= localDo when localWe = '0'
	            else std_logic_vector(di) when accessIO = '0'
	            else ioDir when localA(0) = '0'
	            else currentIO;

	process(clk)
	begin
		if rising_edge(clk) then
			if accessIO = '1' then
				if localWe = '0' and enable = '1' then
					if localA(0) = '0' then
						ioDir <= localDo;
					else
						ioData <= localDo;
					end if;
				end if;
			end if;

			currentIO <= (ioData and ioDir) or (std_logic_vector(diIO) and not ioDir);

			if reset = '1' then
				ioDir <= (others => '0');
				ioData <= (others => '1');
				currentIO <= "00111111";
			end if;
		end if;
	end process;

	-- NMI acknowledge: detect when CPU reads NMI vector (VPB low)
	-- VPB goes low for ALL vectors; check address to distinguish NMI:
	--   NMI: $FFFA/$FFFB (emu) / $FFEA/$FFEB (native) => addr(2)=0, addr(1)=1
	--   IRQ: $FFFE/$FFFF / $FFEE/$FFEF, RESET: $FFFC/$FFFD, etc. differ
	process(clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				nmi_active <= '0';
				nmi_n_prev <= '1';
			elsif enable = '1' then
				nmi_n_prev <= nmi_n;
				if nmi_n_prev = '1' and nmi_n = '0' then
					nmi_active <= '1';
				end if;
				if localVPB = '0' and nmi_active = '1' and localA(2) = '0' and localA(1) = '1' then
					nmi_active <= '0';
				end if;
			end if;
		end if;
	end process;

	nmi_ack <= '1' when localVPB = '0' and nmi_active = '1' and localA(2) = '0' and localA(1) = '1' else '0';

	-- Output assignments
	addr    <= unsigned(localA(15 downto 0));
	addr_hi <= unsigned(localA(23 downto 16));
	do      <= unsigned(localDo);
	we      <= not localWe;  -- invert: T65/P65C816 use active-low R/W#, system uses active-high WE
	doIO    <= unsigned(currentIO);
	emulation_mode <= localEF;
	dbg_sp <= unsigned(localSP);
	dbg_p  <= unsigned(localP);
	dbg_ir <= unsigned(localIR);

end architecture;
