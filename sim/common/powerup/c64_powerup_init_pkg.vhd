library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package c64_powerup_init_pkg is
    -- Power-up init modes used by the reduced Verilator harnesses.
    --
    -- 00 = off  (leave memories at their declaration defaults)
    -- 01 = zero (explicitly write 64KB of $00 before releasing reset)
    -- 10 = vice (deterministic subset of VICE ram.c defaults)
    -- 11 = reserved (currently treated the same as vice)
    --
    -- The VICE-inspired mode mirrors the non-random part of the default
    -- ram_init() parameters in vice/src/ram.c:
    --   start_value          = $00
    --   value_offset         = 2
    --   value_invert         = 4
    --   pattern_invert       = 16384
    --   pattern_invert_value = $FF
    --
    -- We intentionally omit the random bit-flip component so the reduced
    -- harness stays deterministic and easy to diff between runs.
    function c64_powerup_init_byte(
        addr : unsigned(15 downto 0);
        mode : std_logic_vector(1 downto 0)
    ) return unsigned;
end package;

package body c64_powerup_init_pkg is
    function c64_powerup_init_byte(
        addr : unsigned(15 downto 0);
        mode : std_logic_vector(1 downto 0)
    ) return unsigned is
        variable offset_v : integer;
        variable value_v  : integer := 0;
    begin
        if mode = "01" then
            return to_unsigned(0, 8);
        end if;

        -- Default to the deterministic VICE-style power-up stripe pattern
        -- for mode 10 and any currently-reserved non-zero mode.
        offset_v := to_integer(addr);

        if (((offset_v + 2) / 4) mod 2) = 1 then
            if value_v = 0 then
                value_v := 16#FF#;
            else
                value_v := 0;
            end if;
        end if;

        if ((offset_v / 16384) mod 2) = 1 then
            if value_v = 0 then
                value_v := 16#FF#;
            else
                value_v := 0;
            end if;
        end if;

        return to_unsigned(value_v, 8);
    end function;
end package body;
