library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.P65816_pkg.all;

entity P65C816 is
    port( 
        CLK			: in std_logic;
		  RST_N		: in std_logic;
		  CE			: in std_logic;
		  
		  RDY_IN		: in std_logic;
        NMI_N		: in std_logic;  
		  IRQ_N		: in std_logic; 
		  ABORT_N	: in std_logic;   -- just for WAI only
        D_IN		: in std_logic_vector(7 downto 0);
        D_OUT     : out std_logic_vector(7 downto 0);
        A_OUT     : out std_logic_vector(23 downto 0);
        WE  		: out std_logic; 
		  RDY_OUT 	: out std_logic;
		  VPA 		: out std_logic;
		  VDA 		: out std_logic;
		  MLB 		: out std_logic;
		  VPB 		: out std_logic;
		  EF_OUT	: out std_logic;
		  DBG_PC	: out std_logic_vector(15 downto 0);
		  DBG_SP	: out std_logic_vector(15 downto 0);
		  DBG_P	: out std_logic_vector(7 downto 0);
		  DBG_IR	: out std_logic_vector(7 downto 0);
		  DBG_PBR	: out std_logic_vector(7 downto 0);
		  DBG_DBR	: out std_logic_vector(7 downto 0);
		  DBG_X	: out std_logic_vector(15 downto 0);
		  DBG_Y	: out std_logic_vector(15 downto 0);
		  DBG_D	: out std_logic_vector(15 downto 0);
		  DBG_A	: out std_logic_vector(15 downto 0);
		  DBG_STATE	: out std_logic_vector(3 downto 0)
    );
end P65C816;

architecture rtl of P65C816 is

	signal A, X, Y, D, SP, T : std_logic_vector(15 downto 0);
	signal SP_busread        : std_logic_vector(15 downto 0);
	signal PBR, DBR : std_logic_vector(7 downto 0);
	signal P    : std_logic_vector(8 downto 0);
	signal PC    : std_logic_vector(15 downto 0);
	
	signal DR : std_logic_vector(7 downto 0);
	signal EF, XF, MF, oldXF : std_logic;
	signal SB, DB : std_logic_vector(15 downto 0);
	signal EN : std_logic;
   signal MC : MCode_r;
	signal IR, NextIR : std_logic_vector(7 downto 0);
	signal STATE, NextState : unsigned(3 downto 0);
	signal LAST_CYCLE : std_logic;
	signal GotInterrupt : std_logic;
	signal IsResetInterrupt, IsNMIInterrupt, IsIRQInterrupt, IsABORTInterrupt : std_logic;
	signal IsBRKInterrupt, IsCOPInterrupt : std_logic;
	signal JumpTaken, JumpNoOverflow, IsBranchCycle1 : std_logic;
	signal w16 : std_logic;
	signal DLNoZero : std_logic;
	signal WAIExec, STPExec : std_logic;
	signal NMI_SYNC : std_logic;
	signal NMI_ACTIVE, IRQ_ACTIVE : std_logic;
	-- v272: NMOS RMW double-write detection. rmw_decode='1' for the 28
	-- read-modify-write opcodes that operate on memory (matches the
	-- existing process-local `rmw` variable used for MLB). The modify
	-- cycle of those opcodes follows a unique microcode pattern
	-- (LOAD_T="10", OUT_BUS="000", BUS_CTRL[5:3]="100"); when EF=1 we
	-- need to inject an OLD-value write at that cycle to mimic the
	-- NMOS 6502 RMW double-write semantic that DL relies on for VIC
	-- IRQ ack via INC $D019.
	signal rmw_decode       : std_logic;
	signal rmw_modify_cycle : std_logic;
	signal OLD_NMI_N, OLD_NMI2_N : std_logic;
	signal RDY_IN_DELAYED : std_logic;
	signal ADDR_BUS : std_logic_vector(23 downto 0);
	
	-- ALU 
	signal AluR: std_logic_vector(15 downto 0);
	signal AluIntR: std_logic_vector(15 downto 0);
	signal CO, VO, SO, ZO : std_logic;
	
	-- AddrGen 
	signal AA: std_logic_vector(16 downto 0);
	signal AB: std_logic_vector(7 downto 0);
	signal AALCarry : std_logic;
	signal DX: std_logic_vector(15 downto 0);
		
	-- Debug
	signal DBG_DAT_WRr : std_logic;
	signal DBG_BRK_ADDR : std_logic_vector(23 downto 0) := (others => '1');
	signal DBG_CTRL : std_logic_vector(7 downto 0) := (others => '0');
	signal DBG_RUN_LAST : std_logic;
	signal DBG_NEXT_PC: std_logic_vector(15 downto 0);
	signal JSR_RET_ADDR: std_logic_vector(23 downto 0);
	signal JSR_FOUND : std_logic;
	
begin
	
	EN <= RDY_IN and CE and not WAIExec and not STPExec;
	
	IsBranchCycle1 <= '1' when IR(4 downto 0) = "10000" and STATE = "0001" else '0';
	process(IR, P)
	begin
		case IR(7 downto 5) is
			when "000" => JumpTaken <= not P(7); -- BPL
			when "001" => JumpTaken <=     P(7); -- BMI
			when "010" => JumpTaken <= not P(6); -- BVC
			when "011" => JumpTaken <=     P(6); -- BVS
			when "100" => JumpTaken <= not P(0); -- BCC
			when "101" => JumpTaken <=     P(0); -- BCS
			when "110" => JumpTaken <= not P(1); -- BNE
			when "111" => JumpTaken <=     P(1); -- BEQ
			when others => JumpTaken <= '0';
		end case; 
	end process;
	
	DLNoZero <= '0' when D(7 downto 0) = x"00" else '1';

	NextIR <= IR when (STATE /= "0000") else
				 x"00" when GotInterrupt = '1' else 
				 D_IN; 
	
	process(MC, MF, XF, EF, IR, STATE, AALCarry, JumpNoOverflow, IsBranchCycle1, JumpTaken, DLNoZero)
	begin
		case MC.STATE_CTRL is
			when "000" => 
				NextState <= STATE + 1; 
			when "001" => 
				if (AALCarry = '0' and (XF = '1' or EF = '1')) then
					NextState <= STATE + 2;
				else
					NextState <= STATE + 1;
				end if;
			when "010" => 
				if IsBranchCycle1 = '1' and JumpTaken = '1' then
					NextState <= "0010";
				else
					NextState <= "0000";
				end if; 
			when "011" => 
				if JumpNoOverflow = '1' or EF = '0' then
					NextState <= "0000";
				else
					NextState <= STATE + 1;
				end if; 
			when "100" => 
				if (MC.LOAD_AXY(1) = '0' and MF = '0' and EF = '0') or 
					(MC.LOAD_AXY(1) = '1' and XF = '0' and EF = '0') then
					NextState <= STATE + 1; 
				else
					NextState <= "0000";
				end if; 
			when "101" => 
				if DLNoZero = '1' then
					NextState <= STATE + 1; 
				else
					NextState <= STATE + 2; 
				end if;
			when "110" => 
				if (MC.LOAD_AXY(1) = '0' and MF = '0' and EF = '0') or 
					(MC.LOAD_AXY(1) = '1' and XF = '0' and EF = '0') then
					NextState <= STATE + 1; 
				else
					NextState <= STATE + 2; 
				end if; 
			when "111" => 
				if EF = '0' then							--BRK,COP,RTI Native mode
					NextState <= STATE + 1; 
				elsif EF = '1' and IR = x"40" then	--RTI Emulation mode
					NextState <= "0000";
				else											--BRK,COP Emulation mode
					NextState <= STATE + 2; 
				end if; 
			when others => null;
		end case;
	end process;
	
	LAST_CYCLE <= '1' when NextState = "0000" else '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			STATE <= (others=>'0');
			IR <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				IR <= NextIR;
				STATE <= NextState;
			end if;
		end if;
	end process; 
	 
	
	MCode: entity work.MCode
	port map (
		CLK		=> CLK,
		RST_N		=> RST_N,
		EN			=> EN,
		IR			=> NextIR,
		STATE		=> NextState,
		M			=> MC
	);
	
	AddrGen: entity work.AddrGen
	port map (
		CLK   		=> CLK,
		RST_N   		=> RST_N,
		EN   			=> EN,
		LOAD_PC   	=> MC.LOAD_PC,
		PCDec 		=> CO,
		GotInterrupt=> GotInterrupt,
		ADDR_CTRL	=> MC.ADDR_CTRL,
		IND_CTRL		=> MC.IND_CTRL,
		D_IN 			=> D_IN,
		X     		=> X, 
		Y     		=> Y, 
		D     		=> D,
		S     		=> SP,
		T     		=> T,
		DR    		=> DR,
		DBR    		=> DBR,
		e6502			=> EF,
		PC     		=> PC, 
		AA     		=> AA, 
		AB     		=> AB, 
		DX     		=> DX,
		AALCarry     => AALCarry, 
		JumpNoOfl 	=> JumpNoOverflow
	);
	
	
	w16 <= '1' when MC.ALU_CTRL.w16 = '1' else	
			 '0' when IR = x"EB" or IR = x"AB" else	--for XBA,PLB
			 '1' when (IR = x"44" or IR = x"54") and STATE = "0101" else	--for MVN/MVP DEC A
			 '1' when (MC.LOAD_AXY(1) = '0') and MF = '0' and EF = '0' else
			 '1' when (MC.LOAD_AXY(1) = '1') and XF = '0' and EF = '0' else
			 '0';
			 
	-- v261: TSC (BUS_CTRL=101) — in emu mode force high byte to $01 so software
	-- reading SP via TSC sees the page-1-normalized value. Ports iigs commit
	-- 401ea5e behaviour. Defensive: our SP-write paths already normalise to
	-- page 1 (lines 347..400), but a stray non-$01 high byte from RST/XCE
	-- transitions could leak through without this mask.
	SP_busread <= (x"01" & SP(7 downto 0)) when EF = '1' else SP;

	with MC.BUS_CTRL(5 downto 3) select
		SB <= A           when "000",
				X           when "001",
				Y           when "010",
				D           when "011",
				T           when "100",
				SP_busread  when "101",
				x"00" & PBR when "110",
				x"00" & DBR when "111",
				x"0000"	   when others;
	
	with MC.BUS_CTRL(2 downto 0) select
		DB <= x"00" & D_IN when "000",
				D_IN & DR    when "001",
				SB           when "010",
				D            when "011",
				T            when "100",
				x"0001"      when "101",
				x"0000" 		 when others;
			
	ALU: entity work.ALU
	port map (
		CTRL   	=> MC.ALU_CTRL,
		L     	=> SB,
		R     	=> DB,
		w16     	=> w16,
		bcd     	=> P(3),
		CI   	 	=> P(0),
		VI  		=> P(6),
		SI  		=> P(7),
		CO   		=> CO,
		VO    	=> VO,
		SO   		=> SO,
		ZO   		=> ZO,
		RES		=> AluR,
		IntR		=> AluIntR
	);

	MF <= P(5);
	XF <= P(4);
	EF <= P(8);

	-- v272: RMW opcode decode (mirrors the per-process `rmw` variable
	-- at the VPB/MLB stage below). Excludes accumulator-mode INC/DEC
	-- ($1A, $3A) which never touch memory. TSB/TRB ($04/$0C/$14/$1C)
	-- ARE included: SST shows real silicon performs an NMOS-style
	-- double-write on these too in emu mode (v273 verified).
	rmw_decode <=
		'1' when IR = x"06" or IR = x"0E" or IR = x"16" or IR = x"1E" or
		         IR = x"C6" or IR = x"CE" or IR = x"D6" or IR = x"DE" or
		         IR = x"E6" or IR = x"EE" or IR = x"F6" or IR = x"FE" or
		         IR = x"46" or IR = x"4E" or IR = x"56" or IR = x"5E" or
		         IR = x"26" or IR = x"2E" or IR = x"36" or IR = x"3E" or
		         IR = x"66" or IR = x"6E" or IR = x"76" or IR = x"7E" or
		         IR = x"14" or IR = x"1C" or IR = x"04" or IR = x"0C"
		else '0';

	-- v272: NMOS RMW modify-cycle override. Fires when:
	--   * E=1 (emulation mode -- MF is forced to 1 here so 8-bit memory)
	--   * Current opcode is one of the 28 memory RMW instructions
	--   * Microcode is in the modify cycle: LOAD_T="10" (ALU result -> T)
	--     and OUT_BUS="000" (no natural bus output for this cycle).
	-- (v273 broadened: removed BUS_CTRL[5:3]="100" check that only matched
	--  INC/DEC variants. Shift/rotate/TSB/TRB use BUS_CTRL="000100"; the
	--  modify-cycle signature LOAD_T="10"+OUT_BUS="000" is already
	--  unique within rmw_decode=1 microcode, since LOAD_T="10" only
	--  appears at the ALU-result-to-T cycle.)
	-- When asserted: drive D_OUT=T(7:0) (OLD value), force WE=0, and
	-- force ADDR_INC=0 in the address process so the address points at
	-- AA+0 (read/write target) instead of AA+1 (the natural slot 4
	-- address used by the 16-bit-mode read of the high byte).
	rmw_modify_cycle <=
		'1' when EF = '1'
		         and rmw_decode = '1'
		         and MC.LOAD_T = "10"
		         and MC.OUT_BUS = "000"
		    else '0';

	EF_OUT <= EF;
	DBG_PC <= PC;
	DBG_SP <= SP;
	DBG_P  <= P(7 downto 0);
	DBG_IR <= IR;
	DBG_PBR <= PBR;
	DBG_DBR <= DBR;
	DBG_X  <= X;
	DBG_Y  <= Y;
	DBG_D  <= D;
	DBG_A  <= A;
	DBG_STATE <= std_logic_vector(STATE);

	process(CLK, RST_N)
		variable next_xf : std_logic;
	begin
		if RST_N = '0' then
			A <= (others=>'0');
			X <= (others=>'0');
			Y <= (others=>'0');
			SP <= x"0100";
			oldXF <= '1';
		elsif rising_edge(CLK) then
			-- XCE ($FB): Force SP high=$01, X/Y high=0 when involving emulation mode.
			-- P(0)=carry, P(8)=emulation BEFORE the swap. After XCE: new_E=old_C, new_C=old_E.
			-- Force when: entering emulation (P(0)=1), OR leaving emulation (P(8)=1).
			-- Only skip when both=0 (native mode with C=0, stays native).
			-- Fix from iigs_simulation: original only checked P(0), missing native→emu case.
			-- v305 attempt: tried `EN = '1'` guard — did NOT fix the post-XCE drop
			-- on hardware; reverted. Bug is elsewhere; see project_xce_drops_next_instruction.md.
			if (IR = x"FB" and (P(0) = '1' or P(8) = '1') and MC.LOAD_P = "101") then
				X(15 downto 8) <= x"00";
				Y(15 downto 8) <= x"00";
				SP(15 downto 8) <= x"01";
				oldXF <= '1';
			elsif EN = '1' then
				if MC.LOAD_AXY = "110" then 
					if MC.BYTE_SEL(1) = '1' and XF = '0' and EF = '0' then
						X(15 downto 8) <= AluR(15 downto 8);
						X(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1') then
						X(7 downto 0) <= AluR(7 downto 0);
						X(15 downto 8) <= x"00";
					end if;
				end if;
				if MC.LOAD_AXY = "101" then 
					if IR = x"EB" then	--XBA
						A(15 downto 8) <= A(7 downto 0);
						A(7 downto 0) <= A(15 downto 8);
					elsif (MC.BYTE_SEL(1) = '1' and MF = '0' and EF = '0') or
						(MC.BYTE_SEL(1) = '1' and w16 = '1') then
						A(15 downto 8) <= AluR(15 downto 8);
						A(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (MF = '1' or EF = '1') then
						A(7 downto 0) <= AluR(7 downto 0);
					end if;
				end if;
				if MC.LOAD_AXY = "111" then 
					if MC.BYTE_SEL(1) = '1' and XF = '0' and EF = '0'  then
						Y(15 downto 8) <= AluR(15 downto 8);
						Y(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1') then
						Y(7 downto 0) <= AluR(7 downto 0);
						Y(15 downto 8) <= x"00";
					end if;
				end if; 
				
				-- Predict the XF value that P is about to take this edge so
				-- the X/Y high-byte clear fires on the SAME edge as the
				-- XF=0->1 transition. SST/silicon captures final.x with the
				-- high byte already cleared after the PLP/RTI/SEP commit;
				-- the previous oldXF-lagged form fired one cycle too late.
				case MC.LOAD_P is
					when "011" =>                                   -- PLP / RTI
						next_xf := D_IN(4) or EF;
					when "110" =>                                   -- SEP / REP
						if IR(5) = '1' then
							next_xf := XF or (DR(4) and not EF);
						else
							next_xf := XF and not (DR(4) and not EF);
						end if;
					when others =>
						next_xf := XF;
				end case;

				oldXF <= next_xf;
				if next_xf = '1' and XF = '0' and EF = '0' then
					X(15 downto 8) <= x"00";
					Y(15 downto 8) <= x"00";
				end if;
				
				case MC.LOAD_SP is
					when "000" => null;
					when "001"=> 
						if EF = '0' then
							SP <= std_logic_vector(unsigned(SP) + 1);
						else
							SP(15 downto 8) <= x"01";
							SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) + 1);
						end if;
					when "010" => 
						if MC.BYTE_SEL(1) = '0' and w16 = '1' then
							if EF = '0' then
								SP <= std_logic_vector(unsigned(SP) + 1);
							else
								SP(15 downto 8) <= x"01";
								SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) + 1);
							end if;
						end if;
					when "011" => 
						if EF = '0' then
							SP <= std_logic_vector(unsigned(SP) - 1);
						else
							SP(15 downto 8) <= x"01";
							SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) - 1);
						end if;
					when "100" => 
						if EF = '0' then
							SP <= A;
						else
							SP(15 downto 8) <= x"01";
							SP(7 downto 0) <= A(7 downto 0);
						end if;
					when "101" => 
						if EF = '0' then
							SP <= X;
						else
							SP(15 downto 8) <= x"01";
							SP(7 downto 0) <= X(7 downto 0);
						end if;
					when "110"=>
						-- New 65816 pull family ($2B/$6B/$AB = PLD/RTL/PLB).
						-- Full-width 16-bit increment in BOTH modes. In emulation
						-- mode these ops cross the page-1 boundary on the byte
						-- accesses (SST: pull at S=$01FF reads $0200, not $0100),
						-- unlike the old 6502 pulls. SP is re-normalized to page 1
						-- at the instruction boundary by the LAST_CYCLE block below,
						-- so it never RESTS in zero page (the earlier per-cycle
						-- page-1 force fixed the resting value but corrupted the
						-- cross-page access address; see iter-20 SST $2B/$6B/$AB).
						SP <= std_logic_vector(unsigned(SP) + 1);
					when "111" =>
						-- New 65816 push family ($0B/$22/$62/$D4/$F4/$FC =
						-- PHD/JSL/PER/PEI/PEA/JSR(abs,X)). Full-width 16-bit
						-- decrement in BOTH modes; emulation-mode page-cross on the
						-- byte accesses (SST: push at S=$0100 writes $00FF, not
						-- $01FF). Re-normalized at the boundary below.
						SP <= std_logic_vector(unsigned(SP) - 1);
					when others => null;
				end case;
				-- Emulation-mode stack-pointer normalization (iter-20). The new
				-- 16-bit stack ops above decrement/increment SP full-width so their
				-- byte accesses cross page 1 like real WDC silicon; here the high
				-- byte is re-forced to $01 at the instruction boundary so SP rests
				-- in page 1 (prevents the zp-clobber an unguarded full-16-bit SP
				-- caused in Asterix-class decompressors). Old 6502 stack ops keep
				-- their per-cycle page-1 force (LOAD_SP "001"/"011") and never leave
				-- page 1 mid-instruction, so this is a no-op for them. This partial
				-- assignment overrides only SP(15:8) from the case above.
				if EF = '1' and LAST_CYCLE = '1' then
					SP(15 downto 8) <= x"01";
				end if;
				-- RTI native PBR-pull setup (cycle-exact, iter-25). In native mode
				-- RTI pulls a 4th byte (PBR), so the stack pointer must advance one
				-- more than the emu path. Doing this as a dedicated LOAD_SP="000"
				-- microcode cycle is correct in *state* but inserts a spurious
				-- internal cycle that real WDC silicon does not have (its pulls are
				-- combinationally pre-incremented). Instead, on the PCH-pull cycle
				-- (STATE_CTRL="111") of RTI ($40) in native mode only, increment SP
				-- here so the very next cycle reads PBR at S+4 with no extra cycle.
				-- Gated on IR=$40 so it can affect no other opcode; in emu (EF='1')
				-- the PCH pull is the last cycle and must NOT increment (SP=S+3).
				if IR = x"40" and EF = '0' and MC.STATE_CTRL = "111" then
					SP <= std_logic_vector(unsigned(SP) + 1);
				end if;
			end if;
		end if;
	end process;
	
	--Status register
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			P <= "100110100";
		elsif rising_edge(CLK) then
			if EN = '1' then
				case MC.LOAD_P is
					when "000" => P <= P;
					when "001" => 
						if (MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(0) = '1' and (MF = '1' or EF = '1')) or		--A/Mem 8bit
							(MC.LOAD_AXY(1) = '1' and MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1')) or		--X/Y 8bit
							(MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(1) = '1' and (MF = '0' and EF = '0')) or	--A/Mem 16bit
							(MC.LOAD_AXY(1) = '1' and MC.BYTE_SEL(1) = '1' and (XF = '0' and EF = '0')) or	--X/Y 16bit
							(MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(1) = '1' and w16 = '1') or						--A/Mem 16bit
							IR = x"EB" or IR = x"AB" or IR = x"5B" or IR = x"BA" then
							P(1 downto 0) <= ZO & CO; P(7 downto 6) <= SO & VO; -- ALU
						end if;
					when "010" =>
						-- v261 (2026-05-02): align with VICE behaviour.
						-- VICE x64sc (6510core.c:436-475) and xscpu64
						-- (65816core.c:1724-1754) both clear D on IRQ entry
						-- in BOTH native and emu mode. v253's NMOS-style
						-- D-preservation diverged from VICE without fixing
						-- DL anyway, so we match VICE. See
						-- docs/cpu_vice_emulation_comparison.md.
						P(2) <= '1';
						P(3) <= '0';
						-- BRK/COP/IRQ/NMI
					when "011" => P(7 downto 6) <= D_IN(7 downto 6); P(5) <= D_IN(5) or EF; P(4) <= D_IN(4) or EF; P(3 downto 0) <= D_IN(3 downto 0); -- RTI/PLP
					when "100" => 
						case IR(7 downto 6) is
							when "00" => P(0) <= IR(5); -- CLC/SEC 18/38
							when "01" => P(2) <= IR(5); -- CLI/SEI 58/78
							when "10" => P(6) <= '0';   -- CLV B8
							when "11" => P(3) <= IR(5); -- CLD/SED D8/F8
							when others => null;
						end case;
					when "101" => 						-- XCE
						P(8) <= P(0); P(0) <= P(8);
						if P(0) = '1' then
							P(4) <= '1';
							P(5) <= '1';
						end if;
					when "110" => 
						case IR(5) is
							when '1' => P(7 downto 0) <= P(7 downto 0) or (DR(7 downto 6) & (DR(5) and not EF) & (DR(4) and not EF) & DR(3 downto 0)); -- SEP
							when '0' => P(7 downto 0) <= P(7 downto 0) and (not (DR(7 downto 6) & (DR(5) and not EF) & (DR(4) and not EF) & DR(3 downto 0))); -- REP
							when others => null;
						end case;
					when "111" => P(1) <= ZO; 	-- BIT IMM
					when others => null;
				end case;
			end if;
		end if;
	end process;

	--
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			T <= (others=>'0');
			DR <= (others=>'0');
			D <= (others=>'0');
			PBR <= (others=>'0');
			DBR <= (others=>'0');
		elsif rising_edge(CLK) then
			-- XCE per WDC datasheet swaps E<->C only; D is preserved across
			-- mode transitions. The previous "clear D on XCE" hack diverged
			-- from real silicon (CMD SuperCPU, Apple IIgs) and breaks
			-- prelude-based register priming used by SingleStepTests/65816.
			-- Removed 2026-05-02 (v273); regression-checked against the v272
			-- sweep (BASIC, decomp_stress, asterix, DL).
			if EN = '1' then
				DR <= D_IN;
				
				case MC.LOAD_T is
					when "01" => 
						if MC.BYTE_SEL(1) = '1' then
							T(15 downto 8) <= D_IN;
						else 
							T(7 downto 0) <= D_IN;
						end if;
					when "10" => 
						T <= AluR;
					when others => null;
				end case;
				
				case MC.LOAD_DKB is
					when "01" =>
						D <= AluIntR;
					when "10" =>
						-- v261: also clear PBR on hardware IRQ/NMI entry to
						-- match VICE 65816core.c:1753 (`reg_pbr=0` after IRQ
						-- vector load). Previously only BRK/COP cleared PBR;
						-- on a hardware interrupt the else-branch loaded PBR
						-- with the PCL byte from $FFFE — wrong semantically,
						-- though latent in DL because DL never sets PBR.
						if IR = x"00" or IR = x"02"
						   or IsIRQInterrupt = '1' or IsNMIInterrupt = '1' then
							PBR <= (others=>'0');
						else
							PBR <= D_IN;
						end if;
					when "11" => 
						if IR = x"44" or IR = x"54" then	--MVN/MVP 
							DBR <= D_IN;
						else
							DBR <= AluIntR(7 downto 0);
						end if;
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	--Data bus
	-- v272: override with OLD T(7:0) during NMOS RMW modify cycle. T
	-- has not yet latched the ALU result this cycle, so T(7:0) is the
	-- value just read in the previous cycle.
	D_OUT <= T(7 downto 0) when rmw_modify_cycle = '1' else
				P(7) & P(6) & (P(5) or EF) & ((P(4) or (not GotInterrupt and EF)) and not (GotInterrupt and (IsIRQInterrupt or IsNMIInterrupt) and EF)) & P(3 downto 0) when MC.OUT_BUS = "001" else
				PC(15 downto 8) when MC.OUT_BUS = "010" and MC.BYTE_SEL(1) = '1' else
				PC(7 downto 0) when MC.OUT_BUS = "010" and MC.BYTE_SEL(1) = '0' else
				AA(15 downto 8) when MC.OUT_BUS = "011" and MC.BYTE_SEL(1) = '1' else
				AA(7 downto 0) when MC.OUT_BUS = "011" and MC.BYTE_SEL(1) = '0' else
				PBR when MC.OUT_BUS = "100" else
				SB(15 downto 8) when MC.OUT_BUS = "101" and MC.BYTE_SEL(1) = '1' else
				SB(7 downto 0) when MC.OUT_BUS = "101" and MC.BYTE_SEL(1) = '0' else
				DR when MC.OUT_BUS = "110" else
				x"00";
		
	process(MC, IsResetInterrupt, rmw_modify_cycle)
	begin
		WE <= '1';
		-- v272: NMOS RMW modify cycle is normally OUT_BUS="000" (no
		-- write); force WE=0 to issue the OLD-value write.
		if (MC.OUT_BUS /= "000" or rmw_modify_cycle = '1') and IsResetInterrupt = '0' then
			WE <= '0';
		end if;
	end process;

	
	--Interrupts
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			OLD_NMI_N <= '1';
			NMI_SYNC <= '0';
		elsif rising_edge(CLK) then
			if CE = '1' and IsResetInterrupt = '0' then
				OLD_NMI_N <= NMI_N;
				if NMI_N = '0' and OLD_NMI_N = '1' and NMI_SYNC = '0' then
					NMI_SYNC <= '1';
				elsif LAST_CYCLE = '1' and NMI_SYNC = '1' and RDY_IN_DELAYED = '1' and EN = '1' then
					NMI_SYNC <= '0';
				end if;
			end if;
			
			if CE = '1' then
				RDY_IN_DELAYED <= RDY_IN;
			end if;
		end if;
	end process; 
	
	IRQ_ACTIVE <= not IRQ_N and not P(2) and RDY_IN_DELAYED;
	NMI_ACTIVE <= NMI_SYNC and RDY_IN_DELAYED;
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			IsResetInterrupt <= '1';
			IsNMIInterrupt <= '0';
			IsIRQInterrupt <= '0';
			GotInterrupt <= '1';
		elsif rising_edge(CLK) then
			
			if RDY_IN = '1' and CE = '1' then
				if LAST_CYCLE = '1' and EN = '1' then
					if GotInterrupt = '0' then
						GotInterrupt <= IRQ_ACTIVE or NMI_ACTIVE;
					else
						GotInterrupt <= '0';
					end if;
					
					IsResetInterrupt <= '0';
					IsNMIInterrupt <= NMI_ACTIVE;
					IsIRQInterrupt <= IRQ_ACTIVE;
				end if;
			end if;
		end if;
	end process; 
	
	IsBRKInterrupt <= '1' when IR = x"00" else '0';
	IsCOPInterrupt <= '1' when IR = x"02" else '0';
	IsABORTInterrupt <= '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			WAIExec <= '0';
			STPExec <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' and GotInterrupt = '0' then
				if STATE = "0001" then 
					if IR = x"CB" then			-- WAI
						WAIExec <= '1';
					elsif IR = x"DB" then		-- STP
						STPExec <= '1';
					end if;
				end if;
			end if;
			
			if RDY_IN = '1' and CE = '1' then
				if (NMI_SYNC = '1' or IRQ_N = '0' or ABORT_N = '0') and WAIExec = '1' then
					WAIExec <= '0';
				end if;
			end if;
		end if;
	end process; 
	
	
	--Address bus
	process(MC, PC, AA, DX, SP, EF, PBR, DBR, AB, IsResetInterrupt, IsABORTInterrupt, IsNMIInterrupt, IsIRQInterrupt, IsCOPInterrupt, rmw_modify_cycle)
	variable ADDR_INC : unsigned(15 downto 0);
	begin
		ADDR_INC := (15 downto 2 => '0', 1 => MC.ADDR_INC(1), 0 => MC.ADDR_INC(0));
		-- v272: NMOS RMW double-write addresses AA+0 (the operand byte),
		-- not AA+1 (which is the slot 4 default for 16-bit second-byte
		-- access). Zero ADDR_INC so the address mux below produces base+0.
		if rmw_modify_cycle = '1' then
			ADDR_INC := (others => '0');
		end if;
		case MC.ADDR_BUS is
			when "0000" => 
				ADDR_BUS <= PBR & PC; 
				
			when "0001"=> 
				ADDR_BUS <= std_logic_vector((unsigned(DBR) & x"0000") + (x"00" & unsigned(AA(15 downto 0))) + (x"00" & ADDR_INC));
			when "0101"=> 
				ADDR_BUS <= std_logic_vector((unsigned(AB) & x"0000") + ("0000000" & unsigned(AA)) + (x"00" & ADDR_INC));
				
			when "0010"=>
				ADDR_BUS <= PBR & std_logic_vector(unsigned(AA(15 downto 0)) + ADDR_INC);
			when "0110"=>
				-- JMP (abs) $6C and JMP [abs] $DC indirect-pointer reads. The
				-- W65C816 FIXED the NMOS JMP ($xxFF) page-wrap bug -- it reads the
				-- high byte from the next page even in emulation mode (SST $6C:
				-- ptr $A6FF -> hi at $A700, not $A600; $DC: bank at $DC00 not
				-- $DB00). So always full 16-bit increment, both modes. (iter-20:
				-- the earlier EF=1 NMOS-wrap was wrong for the 65816; "0110" is
				-- used ONLY by $6C/$DC, verified -- $7C uses "0010".)
				ADDR_BUS <= x"00" & std_logic_vector(unsigned(AA(15 downto 0)) + ADDR_INC);
				
			when "0011" | "0111" =>
				-- DP indirect pointer-byte read. The +1 (and +2 for long
				-- [dp]/[dp],Y) pointer-byte increment is ALWAYS full 16-bit
				-- on the W65C816 -- it does NOT replicate the NMOS 6502's
				-- zero-page pointer wrap, even in emulation mode with DPL=0.
				-- This is a documented emu-mode incompatibility. SST oracle
				-- (iter-26): EVERY emu DPL=0 case whose ptr+1 crosses a page
				-- carries, never wraps -- e.g. (dp,X) E1/8668 $F4FF->$F500,
				-- [dp] 27/3340 $2FFF->$3000, [dp],Y 17/1411 $B6FF->$B700.
				-- (The earlier EF=1&DPL=0 wrap branch broke E1/8668; it was
				-- never exercised by any case that wanted a wrap. The DPL!=0
				-- "262 fail" fix was really the full-16-bit path, kept here.)
				ADDR_BUS <= x"00" & std_logic_vector(unsigned(DX) + ADDR_INC);
				
			when "1000" | "1100" => 
				if EF = '0' or MC.ADDR_BUS(2) = '0' then
					ADDR_BUS <= x"00" & SP;
				else
					ADDR_BUS <= x"00" & x"01" & SP(7 downto 0);
				end if;
				
			when "1111" => 
				ADDR_BUS(23 downto 4) <= x"00" & "11111111111" & EF;
				if IsResetInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "110" & MC.ADDR_INC(0);		--FFFC/D
				elsif IsABORTInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "100" & MC.ADDR_INC(0);		--FFF8/8, FFE8/9
				elsif IsNMIInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "101" & MC.ADDR_INC(0);		--FFFA/B, FFEA/B
				elsif IsIRQInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "111" & MC.ADDR_INC(0);		--FFFE/F, FFEE/F
				elsif IsCOPInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "010" & MC.ADDR_INC(0);		--FFF4/5, FFE4/5
				else			--BRK Interrupt
					ADDR_BUS(3 downto 0) <= EF & "11" & MC.ADDR_INC(0);	--FFFE/F, FFE6/7
				end if;
				
			when others => 
				ADDR_BUS <= (others=>'0'); 
		end case;
	end process;
	
	A_OUT <= ADDR_BUS;

	process(MC, IR, LAST_CYCLE, STATE, IRQ_ACTIVE, NMI_ACTIVE, IsBRKInterrupt, IsCOPInterrupt, GotInterrupt )
		variable rmw : std_logic;
		variable twoCls, softInt : std_logic;
	begin
		 if IR = x"06" or IR = x"0E" or IR = x"16" or IR = x"1E" or 
			 IR = x"C6" or IR = x"CE" or IR = x"D6" or IR = x"DE" or 
			 IR = x"E6" or IR = x"EE" or IR = x"F6" or IR = x"FE" or 
			 IR = x"46" or IR = x"4E" or IR = x"56" or IR = x"5E" or 
			 IR = x"26" or IR = x"2E" or IR = x"36" or IR = x"3E" or 
			 IR = x"66" or IR = x"6E" or IR = x"76" or IR = x"7E" or 
			 IR = x"14" or IR = x"1C" or IR = x"04" or IR = x"0C" then
			rmw := '1';
		else
			rmw := '0';
		end if;
				
		if MC.ADDR_BUS = "1111" then
			VPB <= '0';
		else
			VPB <= '1';
		end if;

		-- MLB asserts (low) during the read-modify-write portion of any of
		-- the 28 RMW opcodes. Per WDC, the lock covers the read, the
		-- modify (internal), and the write -- but not the operand fetches
		-- or the page-cross IO before the read.
		--   * Operand fetches use ADDR_BUS="0000" (PBR:PC) -> excluded.
		--   * RMW data accesses use ADDR_BUS in {"0001","0011","0101","0111"}
		--     for ABS/DP/ABS,X/STK respectively. The DP,X variants reuse
		--     the DP "0011" pattern. ABS,X uses "0101", which the older
		--     gate omitted entirely (v273 SST sweep caught this).
		--   * The page-cross IO of ABS,X also has ADDR_BUS="0101" but
		--     VA="00" and LOAD_T="00", so we additionally require
		--     VA /= "00" or the modify-cycle signature LOAD_T="10".
		if rmw = '1'
		   and (MC.ADDR_BUS = "0001" or MC.ADDR_BUS = "0011"
		        or MC.ADDR_BUS = "0101" or MC.ADDR_BUS = "0111")
		   and (MC.VA /= "00" or MC.LOAD_T = "10")
		then
			MLB <= '0';
		else
			MLB <= '1';
		end if;
		
		if LAST_CYCLE = '1' and STATE = 1 and MC.VA = "00" then
			twoCls := '1';
		else
			twoCls := '0';
		end if;
		
		if (IsBRKInterrupt = '1' or IsCOPInterrupt = '1') and STATE = 1 and GotInterrupt = '0' then
			softInt := '1';
		else
			softInt := '0';
		end if;
		
		VDA <= MC.VA(1);
		VPA <= MC.VA(0) or (twoCls and (IRQ_ACTIVE or NMI_ACTIVE)) or softInt;
	end process;
	
	RDY_OUT <= EN;

end rtl;