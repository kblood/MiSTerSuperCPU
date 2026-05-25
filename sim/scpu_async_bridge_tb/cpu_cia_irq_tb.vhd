-- cpu_cia_irq_tb.vhd
--
-- Milestone B / Option H (2026-05-25). Derived from cpu_cia_real_tb.vhd.
-- Goal: reproduce the silicon LOAD"*",8,1 wedge in sim by exercising the
-- IRQ-vector-fetch micro-sequence that the prior three benches (all-PASS)
-- intentionally skipped (they all used SEI).
--
-- Difference from cpu_cia_real_tb.vhd:
--   * SEI removed from the test program (CPU starts IRQ-enabled).
--   * cia_irq_n is wired to the CPU's irq_n port (was tied '1' before).
--   * Test program configures CIA1-style Timer A for continuous mode at a
--     short period so several underflows fire during the bench window.
--   * Counts IRQ entries via two complementary signals:
--       - cpu_irq_handler_visits: increments each time the test program's
--         IRQ handler executes its trampoline (writes a marker to $C5).
--       - vec_fetch_count: counts bus accesses to $00FFFE / $00FFFF (the
--         IRQ vector slots) — this is what the proposed HW probe would see.
--   * The CPU's main loop is a poll on $DD0D (ICR) similar to KERNAL IECIN
--     timing, so the IRQ fires while the CPU is mid-LDA $DD0D.
--
-- Test program at $0200 (no SEI; CLI explicit; IRQ vector points at $0260):
--   $0200  D8           CLD             ; clear decimal
--   $0201  A2 FF        LDX #$FF
--   $0203  9A           TXS             ; init SP
--   $0204  A9 10        LDA #$10        ; Timer A latch lo = $10 (short)
--   $0206  8D 04 DD     STA $DD04
--   $0209  A9 00        LDA #$00
--   $020B  8D 05 DD     STA $DD05        ; Timer A latch hi = $00
--   $020E  A9 81        LDA #$81        ; IMR write: bit7=set, bit0=TA enable
--   $0210  8D 0D DD     STA $DD0D
--   $0213  A9 11        LDA #$11        ; CRA: start (bit0=1) + force-load (bit4=1) continuous (bit3=0)
--   $0215  8D 0E DD     STA $DD0E
--   $0218  58           CLI             ; enable IRQs (the experiment)
--   $0219  A9 00        LDA #$00
--   $021B  85 C2        STA $C2          ; iter counter init
--   $021D  85 C5        STA $C5          ; IRQ-handler-visit counter init
-- poll: ($021F)
--   $021F  E6 C2        INC $C2          ; loop iter
--   $0221  AD 0D DD     LDA $DD0D        ; poll ICR (similar to KERNAL IECIN)
--   $0224  C5 C5        CMP $C5          ; compare iter against handler counter
--   $0226  D0 F7        BNE poll         ; loop until they match (won't ever)
--                                       ; actually the loop just keeps going
--   $0228  4C 1F 02     JMP poll         ; (unreachable; for safety)
--                                       ; NOTE: termination is via STOP_TIME_NS,
--                                       ; verdict reads $C5 to count IRQs taken.
--
-- IRQ handler at $0260 (8-byte trampoline):
--   $0260  E6 C5        INC $C5          ; bump handler-visit counter
--   $0262  AD 0D DD     LDA $DD0D        ; clear ICR so irq_n releases
--   $0265  40           RTI
--
-- IRQ vector at $FFFE/$FFFF points at $0260.
--
-- VERDICT (the new dimension):
--   PASS_NO_RACE  = CPU completed loop, handler visited >=3 times, each visit
--                   was followed by main-loop progress. IRQ-race hypothesis
--                   ALSO FALSIFIED — sim is not reproducing the wedge; next
--                   probe MUST be HW-side bridge UART (per design doc §C.3).
--   WEDGE         = CPU advanced but main loop iter ($C2) stops increasing,
--                   or handler-visit count stays 0 despite vec_fetch_count > 0.
--                   This is the silicon wedge reproduced — document the
--                   exact stall (FSM state, last_bus_di) and recommend fix
--                   per design doc §C.1 / §C.2.
--   HARD_WEDGE    = PC never left $0000.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use IEEE.std_logic_textio.all;

entity cpu_cia_irq_tb is
    generic (
        RATIO            : positive  := 2;
        -- 0 = MCP active (the suspect config), 1 = passthrough (regression net).
        PASSTHROUGH_MODE : integer range 0 to 1 := 0;
        -- 500 us by default — at RATIO=2, that's ~16,000 clk_sys, ~4,000
        -- 1MHz "cycles" — plenty for several Timer A underflows at period
        -- $0010 ticks.
        STOP_TIME_NS     : positive  := 500000
    );
end entity;

architecture sim of cpu_cia_irq_tb is

    constant CLK_SYS_PERIOD : time := 31.25 ns;
    constant CLK_CPU_PERIOD : time := CLK_SYS_PERIOD / RATIO;

    function to_sl(i : integer) return std_logic is
    begin
        if i = 0 then return '0'; else return '1'; end if;
    end function;
    constant PASSTHROUGH_SL : std_logic := to_sl(PASSTHROUGH_MODE);

    signal clk_cpu : std_logic := '0';
    signal clk_sys : std_logic := '0';
    signal reset   : std_logic := '1';
    signal res_n   : std_logic;  -- active-low reset for CIA

    -- CPU
    signal cpu_addr     : unsigned(15 downto 0);
    signal cpu_addr_hi  : unsigned(7 downto 0);
    signal cpu_do       : unsigned(7 downto 0);
    signal cpu_we       : std_logic;
    signal cpu_vpa      : std_logic;
    signal cpu_vda      : std_logic;
    signal cpu_di       : unsigned(7 downto 0);
    signal cpu_rdy      : std_logic;

    signal dbg_pc       : unsigned(15 downto 0);
    signal dbg_sp       : unsigned(15 downto 0);
    signal dbg_p        : unsigned(7 downto 0);
    signal dbg_ir       : unsigned(7 downto 0);
    signal dbg_pbr      : unsigned(7 downto 0);
    signal dbg_dbr      : unsigned(7 downto 0);
    signal dbg_x        : unsigned(15 downto 0);
    signal dbg_y        : unsigned(15 downto 0);
    signal dbg_d        : unsigned(15 downto 0);
    signal dbg_state    : unsigned(3 downto 0);

    signal nmi_n          : std_logic := '1';
    signal nmi_ack_unused : std_logic;
    signal irq_n_to_cpu   : std_logic := '1';
    signal emu_mode       : std_logic;
    signal cpu_enable     : std_logic;
    signal diIO           : unsigned(7 downto 0) := (others => '1');
    signal doIO_unused    : unsigned(7 downto 0);

    -- Bridge
    signal bus_addr           : unsigned(15 downto 0);
    signal bus_addr_hi        : unsigned(7 downto 0);
    signal bus_do             : unsigned(7 downto 0);
    signal bus_we             : std_logic;
    signal bus_vpa            : std_logic;
    signal bus_vda            : std_logic;
    signal bus_di             : unsigned(7 downto 0) := (others => '0');
    signal bus_ack_pulse      : std_logic := '0';
    signal bus_request_strobe : std_logic := '0';
    signal dbg_is_slow        : std_logic;

    -- Mock arbiter (4-clk_sys CYCLE_CPUC cadence, identical to cpu_cia_real_tb)
    signal slot_ctr        : unsigned(4 downto 0) := (others => '0');
    signal pending_addr    : unsigned(15 downto 0) := (others => '0');
    signal pending_addr_hi : unsigned(7 downto 0)  := (others => '0');
    signal pending_we      : std_logic := '0';
    signal pending_do      : unsigned(7 downto 0)  := (others => '0');
    signal pending_valid   : std_logic := '0';
    signal ack_delay       : unsigned(1 downto 0) := (others => '0');

    signal phi2_p_pulse : std_logic := '0';
    signal phi2_n_pulse : std_logic := '0';

    -- CIA interface
    signal cs_cia2_n   : std_logic := '1';
    signal cia_rw      : std_logic := '1';
    signal cia_rs      : unsigned(3 downto 0) := (others => '0');
    signal cia_db_in   : unsigned(7 downto 0) := (others => '0');
    signal cia_db_out  : unsigned(7 downto 0);
    signal cia_pa_out  : unsigned(7 downto 0);
    signal cia_pa_oe   : unsigned(7 downto 0);
    signal cia_pb_out  : unsigned(7 downto 0);
    signal cia_pb_oe   : unsigned(7 downto 0);
    signal cia_pc_n    : std_logic;
    signal cia_sp_out  : std_logic;
    signal cia_cnt_out : std_logic;
    signal cia_irq_n   : std_logic;

    -- pa_in stim — irrelevant for this bench (no $DD00 polling) but keep
    -- the port driven to avoid metavalue warnings.
    signal iec_state : unsigned(7 downto 0) := x"00";

    -- Wedge / IRQ observability
    signal pc_ever_left_zero  : std_logic := '0';
    signal max_pc_observed    : unsigned(15 downto 0) := (others => '0');
    signal pa_read_count      : unsigned(15 downto 0) := (others => '0');
    signal icr_read_count     : unsigned(15 downto 0) := (others => '0');
    signal vec_fetch_count    : unsigned(15 downto 0) := (others => '0');
    -- Snapshots of $C2 (iter) over time, sampled at 4 evenly-spaced points
    -- through the bench window — lets us detect "iter stopped advancing".
    signal iter_snap_quarter  : unsigned(7 downto 0) := (others => '0');
    signal iter_snap_half     : unsigned(7 downto 0) := (others => '0');
    signal iter_snap_three_q  : unsigned(7 downto 0) := (others => '0');

    -- Optional: bridge-side counters mirroring the HW probe. Useful when
    -- diagnosing race α / β in sim if the wedge fires.
    signal sim_req_count      : unsigned(15 downto 0) := (others => '0');
    signal sim_ack_count      : unsigned(15 downto 0) := (others => '0');
    signal cpu_req_toggle_d   : std_logic := '0';
    signal bus_ack_pulse_d    : std_logic := '0';

    -- Page 0 + page 1 (zp + stack) RAM. Stack page is REQUIRED for IRQ
    -- testing — the IRQ entry pushes P/PC/PB to $01xx and RTI pulls them
    -- back. Without modelling $01xx as RAM, RTI restores garbage and CPU
    -- jumps into NOP-fill territory; that wedge mode is a bench artifact,
    -- not a bridge bug.
    type zp_ram_t is array (0 to 511) of unsigned(7 downto 0);
    signal zp_ram : zp_ram_t := (others => x"00");

    -- ROM
    function rom_byte(a_hi : unsigned(7 downto 0); a_lo : unsigned(15 downto 0)) return unsigned is
    begin
        if a_hi /= x"00" then
            return x"EA";
        end if;
        case to_integer(a_lo) is
            when 16#FFFC# => return x"00";  -- reset vec lo
            when 16#FFFD# => return x"02";  -- reset vec hi
            when 16#FFFE# => return x"60";  -- irq  vec lo -> $0260
            when 16#FFFF# => return x"02";  -- irq  vec hi
            -- Main program at $0200
            when 16#0200# => return x"D8";  -- CLD
            when 16#0201# => return x"A2";  -- LDX #$FF
            when 16#0202# => return x"FF";
            when 16#0203# => return x"9A";  -- TXS
            when 16#0204# => return x"A9";  -- LDA #$10
            when 16#0205# => return x"10";
            when 16#0206# => return x"8D";  -- STA $DD04
            when 16#0207# => return x"04";
            when 16#0208# => return x"DD";
            when 16#0209# => return x"A9";  -- LDA #$00
            when 16#020A# => return x"00";
            when 16#020B# => return x"8D";  -- STA $DD05
            when 16#020C# => return x"05";
            when 16#020D# => return x"DD";
            when 16#020E# => return x"A9";  -- LDA #$81
            when 16#020F# => return x"81";
            when 16#0210# => return x"8D";  -- STA $DD0D
            when 16#0211# => return x"0D";
            when 16#0212# => return x"DD";
            when 16#0213# => return x"A9";  -- LDA #$11
            when 16#0214# => return x"11";
            when 16#0215# => return x"8D";  -- STA $DD0E
            when 16#0216# => return x"0E";
            when 16#0217# => return x"DD";
            when 16#0218# => return x"58";  -- CLI
            when 16#0219# => return x"A9";  -- LDA #$00
            when 16#021A# => return x"00";
            when 16#021B# => return x"85";  -- STA $C2
            when 16#021C# => return x"C2";
            when 16#021D# => return x"85";  -- STA $C5
            when 16#021E# => return x"C5";
            -- poll: $021F
            when 16#021F# => return x"E6";  -- INC $C2
            when 16#0220# => return x"C2";
            when 16#0221# => return x"AD";  -- LDA $DD0D
            when 16#0222# => return x"0D";
            when 16#0223# => return x"DD";
            when 16#0224# => return x"C5";  -- CMP $C5
            when 16#0225# => return x"C5";
            when 16#0226# => return x"D0";  -- BNE poll (-9 -> $021F)
            when 16#0227# => return x"F7";
            when 16#0228# => return x"4C";  -- JMP poll (safety)
            when 16#0229# => return x"1F";
            when 16#022A# => return x"02";
            -- IRQ handler at $0260
            when 16#0260# => return x"E6";  -- INC $C5
            when 16#0261# => return x"C5";
            when 16#0262# => return x"AD";  -- LDA $DD0D
            when 16#0263# => return x"0D";
            when 16#0264# => return x"DD";
            when 16#0265# => return x"40";  -- RTI
            when others   => return x"EA";  -- NOP fill
        end case;
    end function;

begin

    clk_sys <= not clk_sys after CLK_SYS_PERIOD / 2;
    clk_cpu <= not clk_cpu after CLK_CPU_PERIOD / 2;

    reset <= '1', '0' after 200 ns;
    res_n <= not reset;

    -- Wire CIA irq_n directly to CPU irq_n (no AND with VIC etc. — only CIA
    -- in this bench). The CIA drives '1' (no IRQ) or '0' (IRQ pending).
    irq_n_to_cpu <= cia_irq_n;

    cpu : entity work.cpu_65c816
    port map (
        clk            => clk_cpu,
        enable         => cpu_enable,
        reset          => reset,
        nmi_n          => nmi_n,
        nmi_ack        => nmi_ack_unused,
        irq_n          => irq_n_to_cpu,
        rdy            => cpu_rdy,
        di             => cpu_di,
        do             => cpu_do,
        addr           => cpu_addr,
        we             => cpu_we,
        diIO           => diIO,
        doIO           => doIO_unused,
        addr_hi        => cpu_addr_hi,
        emulation_mode => emu_mode,
        vpa            => cpu_vpa,
        vda            => cpu_vda,
        dbg_pc         => dbg_pc,
        dbg_sp         => dbg_sp,
        dbg_p          => dbg_p,
        dbg_ir         => dbg_ir,
        dbg_pbr        => dbg_pbr,
        dbg_dbr        => dbg_dbr,
        dbg_x          => dbg_x,
        dbg_y          => dbg_y,
        dbg_d          => dbg_d,
        dbg_state      => dbg_state
    );

    bridge : entity work.scpu_async_bridge
    generic map (
        BRIDGE_ACTIVE          => '1',
        CACHE_ACTIVE           => '0',
        SAME_CLOCK_PASSTHROUGH => PASSTHROUGH_SL
    )
    port map (
        clk_cpu               => clk_cpu,
        clk_sys               => clk_sys,
        reset                 => reset,
        cpu_addr_in           => cpu_addr,
        cpu_addr_hi_in        => cpu_addr_hi,
        cpu_do_in             => cpu_do,
        cpu_we_in             => cpu_we,
        cpu_vpa_in            => cpu_vpa,
        cpu_vda_in            => cpu_vda,
        cpu_di_out            => cpu_di,
        cpu_rdy_out           => cpu_rdy,
        bus_addr_out          => bus_addr,
        bus_addr_hi_out       => bus_addr_hi,
        bus_do_out            => bus_do,
        bus_we_out            => bus_we,
        bus_vpa_out           => bus_vpa,
        bus_vda_out           => bus_vda,
        bus_di_in             => bus_di,
        bus_ack_pulse_in      => bus_ack_pulse,
        bus_request_strobe_in => bus_request_strobe,
        cpu_enable_out        => cpu_enable,
        dbg_is_slow           => dbg_is_slow
    );

    -- Decode cs_cia2 — same as cpu_cia_real_tb.
    cs_cia2_n <= '0' when bus_addr_hi = x"00"
                       and bus_addr(15 downto 4) = x"DD0"
                       and (bus_vpa = '1' or bus_vda = '1')
                  else '1';
    cia_rw    <= not bus_we;
    cia_rs    <= bus_addr(3 downto 0);
    cia_db_in <= bus_do;

    cia : entity work.mos6526
    port map (
        clk     => clk_sys,
        mode    => '0',
        phi2_p  => phi2_p_pulse,
        phi2_n  => phi2_n_pulse,
        res_n   => res_n,
        cs_n    => cs_cia2_n,
        rw      => cia_rw,
        rs      => cia_rs,
        db_in   => cia_db_in,
        db_out  => cia_db_out,
        pa_in   => iec_state,
        pa_out  => cia_pa_out,
        pa_oe   => cia_pa_oe,
        pb_in   => x"FF",
        pb_out  => cia_pb_out,
        pb_oe   => cia_pb_oe,
        flag_n  => '1',
        pc_n    => cia_pc_n,
        tod     => '0',
        sp_in   => '1',
        sp_out  => cia_sp_out,
        cnt_in  => '1',
        cnt_out => cia_cnt_out,
        irq_n   => cia_irq_n
    );

    mock_arb : process(clk_sys)
        variable di_v : unsigned(7 downto 0);
    begin
        if rising_edge(clk_sys) then
            if reset = '1' then
                slot_ctr           <= (others => '0');
                pending_valid      <= '0';
                ack_delay          <= (others => '0');
                bus_request_strobe <= '0';
                bus_ack_pulse      <= '0';
                bus_di             <= (others => '0');
                phi2_p_pulse       <= '0';
                phi2_n_pulse       <= '0';
            else
                bus_request_strobe <= '0';
                bus_ack_pulse      <= '0';
                phi2_p_pulse       <= '0';
                phi2_n_pulse       <= '0';

                slot_ctr <= slot_ctr + 1;

                if slot_ctr(1 downto 0) = "00" then
                    phi2_p_pulse <= '1';
                end if;
                if slot_ctr(1 downto 0) = "01" then
                    phi2_n_pulse <= '1';
                end if;
                if slot_ctr(1 downto 0) = "11" then
                    bus_request_strobe <= '1';
                    -- Only latch a NEW request when prior one is done; the
                    -- real arbiter pulses enableCpu_816 once per CPU slot
                    -- but doesn't re-latch the same access across slots.
                    -- Without this gate, the bridge sees ~2x acks per req
                    -- because bus_vpa stays high across multiple "11"
                    -- cycles during the round-trip.
                    if pending_valid = '0' and (bus_vpa = '1' or bus_vda = '1') then
                        pending_addr    <= bus_addr;
                        pending_addr_hi <= bus_addr_hi;
                        pending_we      <= bus_we;
                        pending_do      <= bus_do;
                        pending_valid   <= '1';
                        ack_delay       <= "10";
                    end if;
                end if;

                if pending_valid = '1' then
                    if ack_delay = "00" then
                        bus_ack_pulse <= '1';
                        if pending_addr_hi = x"00"
                            and pending_addr(15 downto 4) = x"DD0" then
                            di_v := cia_db_out;
                            if pending_we = '0' then
                                if pending_addr(3 downto 0) = x"0" then
                                    pa_read_count <= pa_read_count + 1;
                                elsif pending_addr(3 downto 0) = x"D" then
                                    icr_read_count <= icr_read_count + 1;
                                end if;
                            end if;
                        elsif pending_addr_hi = x"00"
                            and (pending_addr(15 downto 8) = x"00"
                                 or pending_addr(15 downto 8) = x"01") then
                            -- Page 0 (zp) and page 1 (stack) both served from
                            -- zp_ram; index is bit 8..0 = 9-bit page+offset.
                            if pending_we = '1' then
                                zp_ram(to_integer(pending_addr(8 downto 0))) <= pending_do;
                                di_v := pending_do;
                            else
                                di_v := zp_ram(to_integer(pending_addr(8 downto 0)));
                            end if;
                        else
                            di_v := rom_byte(pending_addr_hi, pending_addr);
                        end if;
                        bus_di        <= di_v;
                        pending_valid <= '0';
                    else
                        ack_delay <= ack_delay - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- IRQ vector fetch counter: increments when bus_request_strobe captures
    -- an access whose pending address is $00:$FFFE or $00:$FFFF. (We sample
    -- at the same edge the mock arb latches pending_*, so the counter sees
    -- the access exactly when the arbiter would.)
    vec_fetch_proc : process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '0' then
                if pending_valid = '1' and ack_delay = "00" then
                    if pending_addr_hi = x"00"
                       and pending_addr(15 downto 1) = "111111111111111"
                       and pending_we = '0' then
                        vec_fetch_count <= vec_fetch_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Sim-side req/ack counters: mirror what the HW probe would surface.
    -- We don't have direct visibility into the bridge's internal toggles
    -- without poking through hierarchy; instead we count vpa/vda rising
    -- edges on the bridge OUTPUT side (= req-pending fires) vs bus_ack_pulse.
    bridge_count_proc : process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reset = '0' then
                -- Edge-detect bus_vpa/vda assertion. The bridge holds these
                -- high while a request is pending; one rising edge per req.
                if (bus_vpa = '1' or bus_vda = '1') and (cpu_req_toggle_d = '0') then
                    sim_req_count   <= sim_req_count + 1;
                    cpu_req_toggle_d <= '1';
                elsif (bus_vpa = '0' and bus_vda = '0') then
                    cpu_req_toggle_d <= '0';
                end if;

                if bus_ack_pulse = '1' and bus_ack_pulse_d = '0' then
                    sim_ack_count <= sim_ack_count + 1;
                end if;
                bus_ack_pulse_d <= bus_ack_pulse;
            end if;
        end if;
    end process;

    -- Wedge / PC tracker
    wedge_watch : process(clk_cpu)
    begin
        if rising_edge(clk_cpu) then
            if reset = '0' then
                if dbg_pc /= x"0000" then
                    pc_ever_left_zero <= '1';
                end if;
                if dbg_pc > max_pc_observed then
                    max_pc_observed <= dbg_pc;
                end if;
            end if;
        end if;
    end process;

    -- PC trace: log every PC change in a defined window so we can see the
    -- exact sequence around the first IRQ entry. Window chosen short enough
    -- to not flood the log but long enough to catch one IRQ entry+exit.
    pc_trace : process(clk_cpu)
        variable last_pc : unsigned(15 downto 0) := (others => '0');
        variable last_pbr : unsigned(7 downto 0) := (others => '0');
        variable l : line;
    begin
        if rising_edge(clk_cpu) then
            if reset = '0' then
                if (dbg_pc /= last_pc or dbg_pbr /= last_pbr)
                   and now < 80 us
                   and now > 5 us then
                    write(l, string'("[T="));
                    write(l, now);
                    write(l, string'("] PC=$"));
                    hwrite(l, std_logic_vector(dbg_pbr));
                    write(l, string'(":"));
                    hwrite(l, std_logic_vector(dbg_pc));
                    write(l, string'(" P=$"));
                    hwrite(l, std_logic_vector(dbg_p));
                    write(l, string'(" SP=$"));
                    hwrite(l, std_logic_vector(dbg_sp));
                    write(l, string'(" IR=$"));
                    hwrite(l, std_logic_vector(dbg_ir));
                    write(l, string'(" irq_n="));
                    write(l, std_logic'image(cia_irq_n));
                    writeline(output, l);
                    last_pc := dbg_pc;
                    last_pbr := dbg_pbr;
                end if;
            end if;
        end if;
    end process;

    -- Periodic snapshots of the iter counter ($C2) at 25/50/75% of the
    -- bench window. Lets the verdict process see if $C2 stalls partway
    -- (silicon wedge signature).
    snap_proc : process
    begin
        wait for (STOP_TIME_NS / 4) * 1 ns;
        iter_snap_quarter <= zp_ram(16#C2#);
        wait for (STOP_TIME_NS / 4) * 1 ns;
        iter_snap_half    <= zp_ram(16#C2#);
        wait for (STOP_TIME_NS / 4) * 1 ns;
        iter_snap_three_q <= zp_ram(16#C2#);
        wait;
    end process;

    -- Verdict
    stim : process
        variable l : line;
        variable final_iter   : integer;
        variable final_visits : integer;
        variable final_vecs   : integer;
        variable final_reqs   : integer;
        variable final_acks   : integer;
        variable iter_stalled : boolean;
    begin
        wait for STOP_TIME_NS * 1 ns;

        write(l, string'("=== cpu_cia_irq_tb verdict ==="));
        writeline(output, l);
        write(l, string'("RATIO            = "));
        write(l, RATIO);
        writeline(output, l);
        write(l, string'("PASSTHROUGH_MODE = "));
        write(l, PASSTHROUGH_MODE);
        writeline(output, l);
        write(l, string'("STOP_TIME_NS     = "));
        write(l, STOP_TIME_NS);
        writeline(output, l);

        write(l, string'("Final dbg_pc       = $"));
        hwrite(l, std_logic_vector(dbg_pc));
        writeline(output, l);
        write(l, string'("Max  dbg_pc        = $"));
        hwrite(l, std_logic_vector(max_pc_observed));
        writeline(output, l);
        write(l, string'("dbg_p (flags)      = $"));
        hwrite(l, std_logic_vector(dbg_p));
        writeline(output, l);
        write(l, string'("cia_irq_n (final)  = "));
        write(l, std_logic'image(cia_irq_n));
        writeline(output, l);

        write(l, string'("pa_read_count      = "));
        write(l, to_integer(pa_read_count));
        writeline(output, l);
        write(l, string'("icr_read_count     = "));
        write(l, to_integer(icr_read_count));
        writeline(output, l);
        write(l, string'("vec_fetch_count    = "));
        write(l, to_integer(vec_fetch_count));
        writeline(output, l);
        write(l, string'("sim_req_count      = "));
        write(l, to_integer(sim_req_count));
        writeline(output, l);
        write(l, string'("sim_ack_count      = "));
        write(l, to_integer(sim_ack_count));
        writeline(output, l);
        write(l, string'("req-ack gap        = "));
        write(l, to_integer(sim_req_count) - to_integer(sim_ack_count));
        writeline(output, l);

        write(l, string'("zp_ram($C2) iter   = "));
        write(l, to_integer(zp_ram(16#C2#)));
        writeline(output, l);
        write(l, string'("zp_ram($C5) visits = "));
        write(l, to_integer(zp_ram(16#C5#)));
        writeline(output, l);
        write(l, string'("iter snapshots 25/50/75/100% = "));
        write(l, to_integer(iter_snap_quarter));
        write(l, string'(" / "));
        write(l, to_integer(iter_snap_half));
        write(l, string'(" / "));
        write(l, to_integer(iter_snap_three_q));
        write(l, string'(" / "));
        write(l, to_integer(zp_ram(16#C2#)));
        writeline(output, l);

        final_iter   := to_integer(zp_ram(16#C2#));
        final_visits := to_integer(zp_ram(16#C5#));
        final_vecs   := to_integer(vec_fetch_count);
        final_reqs   := to_integer(sim_req_count);
        final_acks   := to_integer(sim_ack_count);
        -- Iter "stalled" = $C2 didn't move between the 50% snapshot and the
        -- final value (the main loop is wedged).
        iter_stalled := (final_iter = to_integer(iter_snap_half))
                         and (final_iter = to_integer(iter_snap_three_q));

        if pc_ever_left_zero = '0' then
            write(l, string'("VERDICT: HARD WEDGE -- PC never left $0000."));
            writeline(output, l);
            assert false report "hard wedge: PC never advanced" severity failure;
        elsif final_visits >= 3 and not iter_stalled and final_iter >= 3 then
            write(l, string'("VERDICT: PASS_NO_RACE -- handler visited "));
            write(l, final_visits);
            write(l, string'(" times, main loop advanced to iter="));
            write(l, final_iter);
            write(l, string'(". IRQ-vector-fetch race FALSIFIED in sim."));
            writeline(output, l);
            write(l, string'("        -> Next probe: HW-side bridge UART (design doc Section B)."));
            writeline(output, l);
        elsif iter_stalled and final_vecs > 0 then
            write(l, string'("VERDICT: WEDGE REPRODUCED -- iter stalled at "));
            write(l, final_iter);
            write(l, string'(", but "));
            write(l, final_vecs);
            write(l, string'(" vector fetches occurred. Race plausibly fires."));
            writeline(output, l);
        elsif final_vecs = 0 then
            write(l, string'("VERDICT: NO_IRQ_FIRED -- CIA never asserted irq_n OR CPU stayed at I=1."));
            writeline(output, l);
            write(l, string'("        Likely test-program bug; not a race finding. Re-check ROM bytes."));
            writeline(output, l);
        else
            write(l, string'("VERDICT: PARTIAL -- handler visited "));
            write(l, final_visits);
            write(l, string'(" / vec_fetch="));
            write(l, final_vecs);
            write(l, string'(" / iter="));
            write(l, final_iter);
            write(l, string'(". Inspect counts."));
            writeline(output, l);
        end if;

        std.env.stop;
    end process;

end architecture;
