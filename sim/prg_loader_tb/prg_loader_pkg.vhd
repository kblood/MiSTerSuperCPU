-- prg_loader_pkg.vhd
--
-- Shared types and helpers for the PRG-loader GHDL bench.
--
-- Scope: purely behavioral. This package does NOT reference any production
-- RTL under C64_MiSTer/. It defines a byte array type used to carry PRG
-- payloads + the scoreboard pointer map, and small conversion utilities.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package prg_loader_pkg is

    -- PRG byte stream: first 2 bytes = little-endian load address,
    -- remaining bytes = payload to copy starting at that address.
    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- Expected BASIC pointer slots after meminit. Mirrors the cases inside
    -- the c64.sv inj_meminit state machine.
    --
    -- $2B/$2C = TXT (always $01 $08)
    -- $2D/$2E = VAR = inj_end (low/high)
    -- $2F/$30 = ARY = inj_end
    -- $31/$32 = STR = inj_end
    -- $AC/$AD = SAVE_START = $00 $00
    -- $AE/$AF = LOAD_END   = inj_end
    type expected_zp_t is record
        txt_lo : std_logic_vector(7 downto 0);
        txt_hi : std_logic_vector(7 downto 0);
        var_lo : std_logic_vector(7 downto 0);
        var_hi : std_logic_vector(7 downto 0);
        ary_lo : std_logic_vector(7 downto 0);
        ary_hi : std_logic_vector(7 downto 0);
        str_lo : std_logic_vector(7 downto 0);
        str_hi : std_logic_vector(7 downto 0);
        save_lo : std_logic_vector(7 downto 0);
        save_hi : std_logic_vector(7 downto 0);
        load_end_lo : std_logic_vector(7 downto 0);
        load_end_hi : std_logic_vector(7 downto 0);
    end record;

    function make_expected_zp(inj_end : unsigned(15 downto 0)) return expected_zp_t;

    function hex2(v : std_logic_vector(7 downto 0))  return string;
    function hex4(v : std_logic_vector(15 downto 0)) return string;

end package;

package body prg_loader_pkg is

    function make_expected_zp(inj_end : unsigned(15 downto 0)) return expected_zp_t is
        variable r  : expected_zp_t;
        variable lo : std_logic_vector(7 downto 0);
        variable hi : std_logic_vector(7 downto 0);
    begin
        lo := std_logic_vector(inj_end(7 downto 0));
        hi := std_logic_vector(inj_end(15 downto 8));
        r.txt_lo := x"01";
        r.txt_hi := x"08";
        r.var_lo := lo; r.var_hi := hi;
        r.ary_lo := lo; r.ary_hi := hi;
        r.str_lo := lo; r.str_hi := hi;
        r.save_lo := x"00"; r.save_hi := x"00";
        r.load_end_lo := lo; r.load_end_hi := hi;
        return r;
    end function;

    function hex_nibble(n : integer) return character is
        constant tbl : string := "0123456789ABCDEF";
    begin
        return tbl(n + 1);
    end function;

    function hex2(v : std_logic_vector(7 downto 0)) return string is
        variable s : string(1 to 2);
    begin
        s(1) := hex_nibble(to_integer(unsigned(v(7 downto 4))));
        s(2) := hex_nibble(to_integer(unsigned(v(3 downto 0))));
        return s;
    end function;

    function hex4(v : std_logic_vector(15 downto 0)) return string is
    begin
        return hex2(v(15 downto 8)) & hex2(v(7 downto 0));
    end function;

end package body;
