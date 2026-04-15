-- cartridge_stub.vhd
--
-- Phase 4b: minimal VHDL stub for the cartridge.v Verilog module.
--
-- NOTE: cartridge.v is instantiated at the c64.sv level, NOT inside
-- fpga64_sid_iec.vhd. The Phase 4b harness does not need it.
--
-- Port list abbreviated from C64_MiSTer/rtl/cartridge.v. Only the
-- ports that a minimal idle "no cartridge inserted" stub needs are
-- modelled. A future harness that instantiates c64.sv can extend this.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cartridge is
    port (
        clk32       : in  std_logic;
        reset_n     : in  std_logic;

        cart_loading: in  std_logic := '0';
        cart_id     : in  std_logic_vector(15 downto 0) := (others => '0');
        cart_exrom  : in  std_logic_vector(7 downto 0)  := (others => '1');
        cart_game   : in  std_logic_vector(7 downto 0)  := (others => '1');

        cpu_ce      : in  std_logic;
        cpu_addr    : in  unsigned(15 downto 0);
        cpu_data    : in  unsigned(7 downto 0);
        cpu_we      : in  std_logic;

        romL        : in  std_logic;
        romH        : in  std_logic;
        UMAXromH    : in  std_logic;
        IOE         : in  std_logic;
        IOF         : in  std_logic;

        game        : out std_logic;
        exrom       : out std_logic;
        io_rom      : out std_logic;
        io_ext      : out std_logic;
        io_data     : out unsigned(7 downto 0);

        freeze_key  : in  std_logic;
        nmi         : out std_logic;
        nmi_ack     : in  std_logic
    );
end entity;

architecture stub of cartridge is
begin
    -- No cartridge: game/exrom both high (inactive)
    game    <= '1';
    exrom   <= '1';
    io_rom  <= '0';
    io_ext  <= '0';
    io_data <= (others => '1');
    nmi     <= '0';
end architecture;
