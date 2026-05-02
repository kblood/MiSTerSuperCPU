-- sst_mem_pkg.vhd
--
-- Sparse 24-bit memory for the SingleStepTests harness. Banks ($00..$FF)
-- are allocated lazily via access types — only banks the test case
-- actually touches consume host memory. Reads to unallocated banks
-- return $00 (matches SST suite's "default initial RAM = 0" semantics).
--
-- Wrapped in a VHDL-2008 protected type so the same shared-variable
-- mem can be both read combinationally (D_IN driven from read()) and
-- written from a clocked process.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sst_mem_pkg is

    type byte_t is array (natural range <>) of std_logic_vector(7 downto 0);
    type page_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    type page_ptr is access page_t;
    type bank_t is array (0 to 255) of page_ptr;

    type sst_mem_t is protected
        impure function read24(addr : unsigned(23 downto 0)) return std_logic_vector;
        procedure write24(addr : unsigned(23 downto 0); val : std_logic_vector(7 downto 0));
        procedure clear_all;
    end protected sst_mem_t;

end package sst_mem_pkg;

package body sst_mem_pkg is

    type sst_mem_t is protected body
        variable banks : bank_t := (others => null);

        impure function read24(addr : unsigned(23 downto 0)) return std_logic_vector is
            variable b : integer;
            variable o : integer;
        begin
            b := to_integer(addr(23 downto 16));
            o := to_integer(addr(15 downto 0));
            if banks(b) = null then
                return x"00";
            end if;
            return banks(b)(o);
        end function read24;

        procedure write24(addr : unsigned(23 downto 0); val : std_logic_vector(7 downto 0)) is
            variable b : integer;
            variable o : integer;
            variable p : page_ptr;
        begin
            b := to_integer(addr(23 downto 16));
            o := to_integer(addr(15 downto 0));
            if banks(b) = null then
                p := new page_t'(others => x"00");
                banks(b) := p;
            end if;
            banks(b)(o) := val;
        end procedure write24;

        procedure clear_all is
        begin
            for i in 0 to 255 loop
                if banks(i) /= null then
                    deallocate(banks(i));
                    banks(i) := null;
                end if;
            end loop;
        end procedure clear_all;

    end protected body sst_mem_t;

end package body sst_mem_pkg;
