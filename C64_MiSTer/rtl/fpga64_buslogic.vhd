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

-- -----------------------------------------------------------------------
-- Dar 08/03/2014
--
-- Based on mixing both fpga64_buslogic_roms and fpga64_buslogic_nommu
-- RAM should be external SRAM
-- Basic, Char and Kernel ROMs are included
-- Original Kernel replaced by JiffyDos
-- -----------------------------------------------------------------------

library IEEE;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

entity fpga64_buslogic is
	port (
		clk         : in std_logic;
		reset       : in std_logic;
		bios        : in std_logic_vector(1 downto 0);

		cpuHasBus   : in std_logic;
		aec         : in std_logic;

		ramData     : in unsigned(7 downto 0);

		-- 2 CHAREN
		-- 1 HIRAM
		-- 0 LORAM
		bankSwitch  : in unsigned(2 downto 0);

		-- From cartridge port
		game        : in std_logic;
		exrom       : in std_logic;
		io_rom      : in std_logic;
		io_ext      : in std_logic;
		io_data     : in unsigned(7 downto 0);

		c64rom_addr : in std_logic_vector(13 downto 0);
		c64rom_data : in std_logic_vector(7 downto 0);
		c64rom_wr   : in std_logic;

		cpuWe       : in std_logic;
		cpuAddr     : in unsigned(15 downto 0);
		cpuData     : in unsigned(7 downto 0);
		vicAddr     : in unsigned(15 downto 0);
		vicData     : in unsigned(7 downto 0);
		sidData     : in unsigned(7 downto 0);
		colorData   : in unsigned(3 downto 0);
		cia1Data    : in unsigned(7 downto 0);
		cia2Data    : in unsigned(7 downto 0);
		lastVicData : in unsigned(7 downto 0);

		io_enable   : in std_logic;

		systemWe    : out std_logic;
		systemAddr  : out unsigned(15 downto 0);
		dataToCpu   : out unsigned(7 downto 0);
		dataToVic   : out unsigned(7 downto 0);

		cs_vic      : out std_logic;
		cs_sid      : out std_logic;
		cs_color    : out std_logic;
		cs_cia1     : out std_logic;
		cs_cia2     : out std_logic;
		cs_ram      : out std_logic;

		-- To catridge port
		cs_ioE      : out std_logic;
		cs_ioF      : out std_logic;
		cs_romL     : out std_logic;
		cs_romH     : out std_logic;
		cs_UMAXromH : out std_logic;

		-- Phase C — SuperCPU integration. supercpu_en='0' (default) keeps
		-- vanilla behavior bit-identical: ROM + I/O paths fall through
		-- unchanged. supercpu_en='1' activates kickstart ROM at $E000-$FFFF
		-- (gated by rom_vis), bank $F8 ROM, bank $00 $8000-$9FFF kickstart
		-- shadow, 512B sysram at $D200-$D3FF, and bank-≠-$00 I/O suppression.
		supercpu_en      : in std_logic := '0';
		supercpu_rom     : in std_logic := '0';                          -- '1' = SuperCPU kickstart ROM compiled in (always 1 on this branch)
		supercpu_rom_vis : in std_logic := '0';                          -- '1' = SuperCPU ROM at $E000-$FFFF; '0' = C64 KERNAL
		supercpu_bank    : in std_logic_vector(7 downto 0) := x"00";     -- 65C816 bank byte (A23-A16)
		scpu_native_mode : in std_logic := '0'                           -- '1' = P65C816 in native mode (E=0); enables bank-$00 ROM-shadow for SCPU CPU reads
	);
end fpga64_buslogic;

-- -----------------------------------------------------------------------

architecture rtl of fpga64_buslogic is
	signal charData       : std_logic_vector(7 downto 0);
	signal charData_std   : std_logic_vector(7 downto 0);
	signal romData        : std_logic_vector(7 downto 0);
	signal romData_c64    : std_logic_vector(7 downto 0);
	-- M10K R1 (Phase C): kernel_c64gs/c64std/c64jap dproms + chargen_j removed.
	-- Frees ~52 M10K blocks (verified at deploy: RAM 71% → 61%). Master used
	-- this same reclamation to fit the 64KB SuperCPU kickstart dprom; on this
	-- branch we don't instantiate that dprom either (see below) and just keep
	-- the headroom. The bios input port is preserved for entity-signature
	-- compatibility but has no effect on KERNAL/chargen choice (JiffyDOS + std
	-- chargen are the only options now).

	signal cs_CharLoc     : std_logic;
	signal cs_romLoc      : std_logic;
	signal vicCharLoc     : std_logic;

	signal cs_ramLoc      : std_logic;
	signal cs_vicLoc      : std_logic;
	signal cs_sidLoc      : std_logic;
	signal cs_colorLoc    : std_logic;
	signal cs_cia1Loc     : std_logic;
	signal cs_cia2Loc     : std_logic;
	signal cs_ioELoc      : std_logic;
	signal cs_ioFLoc      : std_logic;
	signal cs_romLLoc     : std_logic;
	signal cs_romHLoc     : std_logic;
	signal cs_UMAXromHLoc : std_logic;
	signal cs_UMAXnomapLoc: std_logic;
	signal ultimax        : std_logic;

	signal currentAddr    : unsigned(15 downto 0);

	-- Phase C — SuperCPU placeholder signals. The kickstart-ROM and SYSRAM
	-- dproms were removed because their M10K placement disturbs vanilla's
	-- fitter result. Kept here as constants so the dataToCpu mux structure
	-- below stays identical to master's, with all clauses gated false in
	-- vanilla mode and trivially in SuperCPU mode.
	signal scpuRomData    : std_logic_vector(7 downto 0);
	signal scpu_rom_en    : std_logic;
	signal scpu_sysram_cs   : std_logic;
	signal scpu_sysram_data : std_logic_vector(7 downto 0);
	signal scpu_io_en       : std_logic;

begin
	chargen: entity work.dprom
	generic map ("rtl/roms/chargen.mif", 12)
	port map
	(
		wrclock => clk,
		rdclock => clk,

		rdaddress => std_logic_vector(currentAddr(11 downto 0)),
		q => charData_std
	);

	-- M10K R1: chargen_j and kernel_c64gs dproms removed.

	kernel_c64: entity work.dprom
	generic map ("rtl/roms/dol_C64.mif", 14)
	port map
	(
		wrclock => clk,
		rdclock => clk,

		wren => c64rom_wr,
		data => c64rom_data,
		wraddress => c64rom_addr,

		rdaddress => std_logic_vector(cpuAddr(14) & cpuAddr(12 downto 0)),
		q => romData_c64
	);

	-- M10K R1: kernel_c64std and kernel_c64jap dproms removed.

	-- v298 (2026-05-10): SuperCPU EPROM dprom REINSTATED. The Phase C
	-- decision to omit it (2026-04-29) was made to keep this branch
	-- vanilla-timing-clean. Doom debugging 2026-05-09..10 traced the
	-- bank-$0F BRK-march wedge to dispatch into empty SuperRAM banks
	-- AND to our IRQ stub bypassing the user-handler chain that real
	-- SCPU EPROM provides at $00:$8025 (chains via $0314 RAM vector).
	-- Without the EPROM, Doom's recompiler-emitted JSLs into bank $F8
	-- routines hit our $6B-RTL stub and lose the routine's effect.
	--
	-- Lifted from master's instantiation. The dprom adds ~52 M10K
	-- blocks (61% → ~71% RAM usage). Vanilla-mode timing impact is
	-- accepted on this branch — the lean baseline was for the early
	-- vanilla-cpu-swap exploration, but we've added enough SuperCPU
	-- support since then that vanilla-clean is no longer the goal.
	scpu_rom: entity work.dprom
	generic map ("rtl/roms/scpu64.mif", 16)
	port map
	(
		wrclock => clk,
		rdclock => clk,

		rdaddress => std_logic_vector(cpuAddr),
		q => scpuRomData
	);

	romData <= romData_c64;

	-- M10K R1: collapsed mux — only std chargen (no Japanese variant).
	charData <= charData_std;

	-- Phase C placeholder decode. With no kickstart dprom or sysram in this
	-- build, the SuperCPU read paths reduce to: bank $00 = vanilla C64
	-- decode (ROM/RAM/I/O), bank ≠ $00 = SuperRAM via SDRAM (Phase D mux
	-- in c64.sv). I/O gating still suppresses C64 chip selects when the
	-- 65C816 is in a non-zero bank so MVN block-moves don't trigger VIC/
	-- SID/CIA writes.
	-- v298: bank $F8 reads → scpuRomData (kickstart EPROM). Other banks
	-- ($F0-$F7, $F9-$FF) remain SuperRAM. Native-mode-only — emu mode
	-- never emits bank-$F8 reads. cpuWe='0' guard mirrors master.
	scpu_rom_en      <= '1' when supercpu_en = '1' and scpu_native_mode = '1'
	                              and supercpu_bank = x"F8" and cpuWe = '0' else '0';
	scpu_sysram_cs   <= '0';
	scpu_sysram_data <= (others => '0');
	scpu_io_en       <= '1' when supercpu_en = '0' or supercpu_bank = x"00" else '0';

	-- M10K R1: bios-selector process removed (the *_ena signals it drove
	-- now have no consumers after the dprom mux collapse).

	--
	--begin
	-- Phase C bisect step 2: re-add SuperCPU dataToCpu clauses. All three
	-- new clauses are gated by supercpu_en='1' (directly or via scpu_rom_en /
	-- scpu_sysram_cs), so vanilla mode collapses to the vanilla else-chain.
	process(ramData, vicData, sidData, colorData,
           cia1Data, cia2Data, charData, romData,
			  cs_romHLoc, cs_romLLoc, cs_romLoc, cs_CharLoc,
			  cs_ramLoc, cs_vicLoc, cs_sidLoc, cs_colorLoc,
			  cs_cia1Loc, cs_cia2Loc, lastVicData,
			  cs_ioELoc, cs_ioFLoc,
			  io_rom, io_ext, io_data,
			  supercpu_en, supercpu_bank, scpu_native_mode,
			  scpuRomData)
	begin
		dataToCpu <= lastVicData;
		-- 2026-05-09 vanilla-cpu-swap: CMD bootmap stub for banks $F0-$FF.
		-- Real CMD SuperCPU has ROM in banks $F0-$FF (bootmap with KERNAL,
		-- CMD library routines, init code). Our MiSTer has nothing there
		-- (SuperRAM SDRAM zeros). Doom JSLs into a CMD library routine
		-- (e.g. JSL $FC:EE1D) and lands in zeros — every $00 fetched is a
		-- BRK, which traps to $FF00 ack stub, RTI returns PC+2, and the
		-- main thread walks bank $FC executing BRKs forever (observed in
		-- doom_full UART t=240s, pc_main = $FC:$EE6D..$EEF9, J ring all
		-- $XXEE1D).
		--
		-- Stub fix: return $6B (RTL opcode) for reads in bank $F6-$FF in
		-- native SCPU mode. Any JSL into this region lands on a 1-byte RTL
		-- that pops the long return address from stack and bounces straight
		-- back to the caller. Doom doesn't get the real routine's effect,
		-- but it also doesn't wedge — caller can take the next code path
		-- and we see what blocks Doom NEXT.
		--
		-- Range $F6-$FF (NOT $F0-$FF): per AmiDog's recomp.txt (the MIPS
		-- recompiler that produced doom.bin) the memory map is
		--   $00800000-$00f5ffff  MIPS executable + heap + stack
		--   $00f60000-$00ffffff  Reserved (SuperCPU system DRAM/ROM)
		-- Bank $F0-$F5 holds legitimate heap/stack data (linker script
		-- mips.x: __stack_end = $00f60000) — returning $6B here corrupts
		-- Doom's heap reads. Only $F6+ should serve the stub.
		--
		-- Highest priority clause (above bank-$01 shadow + bank-≠-$00 SDRAM)
		-- because supercpu_bank=$F6+ falls into the bank-≠-$00 SDRAM path
		-- otherwise. Native-mode-only — emu mode never emits bank-$F6+ reads.
		--
		-- v298: bank $F8 specifically → SuperCPU EPROM (scpuRomData). The
		-- 64KB scpu64.mif holds CMD library routines, IRQ handler entry
		-- ($00:$8025 → JML target inside the EPROM at $F8:$8025 if the
		-- recompiler-emitted code reaches there), and kickstart code. Other
		-- banks $F6, $F7, $F9-$FF keep the $6B-RTL stub since real EPROM
		-- only lives at $F8 (per master's mapping).
		if supercpu_en = '1' and scpu_native_mode = '1' and supercpu_bank = x"F8" then
			dataToCpu <= unsigned(scpuRomData);
		elsif supercpu_en = '1' and scpu_native_mode = '1' and unsigned(supercpu_bank) >= x"F6" then
			dataToCpu <= x"6B";
		-- Bank-$01 SRAM ROM shadow (Tier 2.1 spec gap). Real CMD SuperCPU's
		-- bank $01 SRAM is pre-loaded with KERNAL/BASIC/CHARGEN ROM copies
		-- so SCPU CPU reads at $01:$E000-$FFFF return KERNAL bytes,
		-- $01:$A000-$BFFF return BASIC bytes, etc. Our bank $01 = SuperRAM
		-- SDRAM (zeros at boot). MIPS-recompiler runtimes that read bank $01
		-- ROM areas for KERNAL data get garbage. This clause synthesizes the
		-- ROM bytes for those reads. Writes to $01:$Exxx still go to SDRAM
		-- via the cs_ram path (effectively read-only ROM, since the shadow
		-- always wins on reads — matches "ROM" semantics, slight divergence
		-- from real CMD which has writable SRAM but with KERNAL pre-loaded).
		-- Native mode only (scpu_native_mode='1') because emu mode never
		-- emits bank-$01 reads (no DBR effect, no long addressing).
		elsif supercpu_en = '1' and scpu_native_mode = '1' and supercpu_bank = x"01"
		                    and (cs_romLoc = '1' or cs_CharLoc = '1') then
			if cs_CharLoc = '1' then
				dataToCpu <= unsigned(charData);
			else
				dataToCpu <= unsigned(romData);
			end if;
		-- Phase C: in SuperCPU mode, bank ≠ $00 reads come from SuperRAM
		-- (SDRAM path; Phase D mux in c64.sv selects which SDRAM bank).
		-- All other clauses fall through to the vanilla else-chain.
		elsif supercpu_en = '1' and supercpu_bank /= x"00" then
			dataToCpu <= ramData;
		-- Bank-$00 SRAM ROM shadow for SCPU CPU reads, native mode only.
		-- Real CMD SuperCPU has 128KB SRAM mirroring banks $00-$01 that
		-- fully displaces the C64 KERNAL/BASIC/CHARGEN/Cart ROMs from the
		-- SCPU CPU's read path (writes already go to RAM under ROM in
		-- vanilla C64; this just makes reads see the RAM too). Required:
		--   1. Native-mode 16-bit SP can park in $00:$Fxxx without RTI
		--      popping KERNAL ROM bytes instead of pushed return address
		--      (Doom symptom — see project_doom_wedge_is_kernal_rom_stack_shadow).
		--   2. Software-installed JML trampoline at $00:$FCEE-$FCF1 reads
		--      the user-installed JML target from RAM, not KERNAL bytes.
		--   3. Bank-$00 SRAM behavior matches real CMD spec.
		-- ESSENTIAL: gated on scpu_native_mode='1' (E=0). At cold boot the
		-- CPU is in EMU mode and reads RESET vector at $00:$FFFC ($E2 $FC
		-- → KERNAL $FCE2). Without the native-mode gate, the shadow returns
		-- RAM=$00 instead of ROM at boot and the system never starts. The
		-- gate also keeps EMU-mode KERNAL execution intact.
		-- The fpga64_sid_iec cpuDi mux still overrides $FF00-$FF1A (ack
		-- stub), $FCEE-$FCF1 (trampoline default), $D27C-$D27F, and the
		-- native vector intercepts at higher priority; this clause only
		-- matters for the rest of the $E000-$FFFF / $A000-$BFFF / $D000-$DFFF
		-- ROM-mapped windows in native mode.
		-- VIC and 6510/T65 paths are unaffected — dataToVic uses its own
		-- mux below, and supercpu_en='0' makes this clause inert.
		elsif supercpu_en = '1' and scpu_native_mode = '1'
		                       and (cs_romLoc = '1' or cs_CharLoc = '1'
		                         or cs_romHLoc = '1' or cs_romLLoc = '1') then
			dataToCpu <= ramData;
		elsif cs_CharLoc = '1' then
			dataToCpu <= unsigned(charData);
		elsif cs_romLoc = '1' then
			dataToCpu <= unsigned(romData);
		elsif cs_ramLoc = '1' then
			dataToCpu <= ramData;
		elsif cs_vicLoc = '1' then
			dataToCpu <= vicData;
		elsif cs_sidLoc = '1' then
			dataToCpu <= sidData;
		elsif cs_colorLoc = '1' then
			dataToCpu(3 downto 0) <= colorData;
		elsif cs_cia1Loc = '1' then
			dataToCpu <= cia1Data;
		elsif cs_cia2Loc = '1' then
			dataToCpu <= cia2Data;
		elsif cs_romLLoc = '1' then
			dataToCpu <= ramData;
		elsif cs_romHLoc = '1' then
			dataToCpu <= ramData;
		elsif cs_ioELoc = '1' and io_rom = '1' then
			dataToCpu <= ramData;
		elsif cs_ioFLoc = '1' and io_rom = '1' then
			dataToCpu <= ramData;
		elsif cs_ioELoc = '1' and io_ext = '1' then
			dataToCpu <= io_data;
		elsif cs_ioFLoc = '1' and io_ext = '1' then
			dataToCpu <= io_data;
		end if;
	end process;

	ultimax <= exrom and (not game);

	process(cpuHasBus, cpuAddr, ultimax, cpuWe, bankSwitch, exrom, game, aec, vicAddr)
	begin
		currentAddr <= (others => '1');
		systemWe <= '0';
		vicCharLoc <= '0';
		cs_CharLoc <= '0';
		cs_romLoc <= '0';
		cs_ramLoc <= '0';
		cs_vicLoc <= '0';
		cs_sidLoc <= '0';
		cs_colorLoc <= '0';
		cs_cia1Loc <= '0';
		cs_cia2Loc <= '0';
		cs_ioELoc <= '0';
		cs_ioFLoc <= '0';
		cs_romLLoc <= '0';
		cs_romHLoc <= '0';
		cs_UMAXromHLoc <= '0';		-- Ultimax flag for the VIC access - LCA
		cs_UMAXnomapLoc <= '0';

		if (cpuHasBus = '1') then
			-- The 6502 CPU has the bus.
			currentAddr <= cpuAddr;
			case cpuAddr(15 downto 12) is
			when X"E" | X"F" =>
				if ultimax = '1' then
					-- pass cpuWe to cartridge. Cartridge must block writes if no RAM connected.
					cs_romHLoc <= '1';
				elsif cpuWe = '0' and bankSwitch(1) = '1' then
					-- Read kernal
					cs_romLoc <= '1';
				else
					-- 64Kbyte RAM layout
					cs_ramLoc <= '1';
				end if;
			when X"D" =>
				if ultimax = '0' and bankSwitch(1) = '0' and bankSwitch(0) = '0' then
					-- 64Kbyte RAM layout
					cs_ramLoc <= '1';
				elsif ultimax = '1' or bankSwitch(2) = '1' then
					case cpuAddr(11 downto 8) is
						when X"0" | X"1" | X"2" | X"3" =>
							cs_vicLoc <= '1';
						when X"4" | X"5" | X"6" | X"7" =>
							cs_sidLoc <= '1';
						when X"8" | X"9" | X"A" | X"B" =>
							cs_colorLoc <= '1';
						when X"C" =>
							cs_cia1Loc <= '1';
						when X"D" =>
							cs_cia2Loc <= '1';
						when X"E" =>
							cs_ioELoc <= '1';
						when X"F" =>
							cs_ioFLoc <= '1';
						when others =>
							null;
					end case;
				else
					-- I/O space turned off. Read from charrom or write to RAM.
					if cpuWe = '0' then
						  cs_CharLoc <= '1';
					else
						  cs_ramLoc <= '1';
					end if;
				end if;
			when X"A" | X"B" =>
				if ultimax = '1' then
					cs_UMAXnomapLoc <= '1';
				elsif exrom = '0' and game = '0' and bankSwitch(1) = '1' then
				  -- this case should write to both C64 RAM and Cart RAM (if RAM is connected)
					cs_romHLoc <= '1';
				elsif ultimax = '0' and cpuWe = '0' and bankSwitch(1) = '1' and bankSwitch(0) = '1' then
					-- Access basic rom
					-- May need turning off if kernal banked out LCA
					cs_romLoc <= '1';
				else
					cs_ramLoc <= '1';
				end if;
			when X"8" | X"9" =>
				if ultimax = '1' then
					-- pass cpuWe to cartridge. Cartridge must block writes if no RAM connected.
					cs_romLLoc <= '1';
				elsif exrom = '0' and bankSwitch(1) = '1' and bankSwitch(0) = '1' then
				  -- this case should write to both C64 RAM and Cart RAM (if RAM is connected)
					cs_romLLoc <= '1';
				else
					cs_ramLoc <= '1';
				end if;
			when X"0" =>
				cs_ramLoc <= '1';
			when others =>
				-- If not in Ultimax mode access ram
				if ultimax = '0' then
					cs_ramLoc <= '1';
				else
					cs_UMAXnomapLoc <= '1';
				end if;
			end case;

			systemWe <= cpuWe;
		else
			-- The VIC-II has the bus, but only when aec is asserted
			if aec = '1' then
				currentAddr <= vicAddr;
			else
				currentAddr <= cpuAddr;
			end if;

			if ultimax = '0' and vicAddr(14 downto 12)="001" then
				vicCharLoc <= '1';
			elsif ultimax = '1' and vicAddr(13 downto 12)="11" then
				-- ultimax mode changes vic addressing - LCA 
				cs_UMAXromHLoc <= '1';
			else
				cs_ramLoc <= '1';
			end if;
		end if;
	end process;

	cs_ram <= cs_ramLoc or cs_romLLoc or cs_romHLoc or cs_UMAXromHLoc or cs_UMAXnomapLoc or cs_CharLoc or cs_romLoc;
	-- Phase C step 4: gate C64 chip-selects with scpu_io_en so MVN/STA-long
	-- accesses into bank /= $00 don't produce stray VIC/SID/CIA strobes. In
	-- vanilla mode (supercpu_en='0') scpu_io_en is constant '1' and these
	-- expressions reduce to the original `cs_X <= cs_XLoc and io_enable`.
	cs_vic <= cs_vicLoc and io_enable and scpu_io_en;
	cs_sid <= cs_sidLoc and io_enable and scpu_io_en;
	cs_color <= cs_colorLoc and io_enable and scpu_io_en;
	cs_cia1 <= cs_cia1Loc and io_enable and scpu_io_en;
	cs_cia2 <= cs_cia2Loc and io_enable and scpu_io_en;
	cs_ioE <= cs_ioELoc and io_enable and scpu_io_en;
	cs_ioF <= cs_ioFLoc and io_enable and scpu_io_en;
	cs_romL <= cs_romLLoc;
	cs_romH <= cs_romHLoc;
	cs_UMAXromH <= cs_UMAXromHLoc;

	dataToVic  <= unsigned(charData) when vicCharLoc = '1' else ramData;
	systemAddr <= currentAddr;
end architecture;
