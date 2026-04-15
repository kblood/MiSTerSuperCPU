-- rom_loader_pkg.vhd
--
-- Phase 4b: ROM file loader for the real fpga64_sid_iec.vhd harness.
--
-- Supports loading a C64 KERNAL+BASIC ROM image via the c64rom_wr/addr/data
-- handshake that fpga64_buslogic.vhd exposes for its `kernel_c64` dprom
-- instance (the "dol_C64" slot). When bios="00" is driven, this is the ROM
-- that the buslogic serves at $A000 (BASIC) and $E000 (KERNAL).
--
-- File resolution order (first match wins):
--   1. sim/common/roms/kernal_basic_16k.bin  (preferred: single 16 KB blob;
--      BASIC at offset 0, KERNAL at offset 0x2000)
--   2. sim/common/roms/basic.bin + sim/common/roms/kernal.bin
--      (separate 8 KB halves)
--   3. None — CPU runs against uninitialised dprom (GHDL leaves it at 'U')
--
-- CHARGEN is not loaded (no runtime write port on the buslogic chargen
-- dprom). The bench does not display any video so chargen-invalid reads
-- are harmless unless the CPU itself tries to LDA from the character ROM
-- region ($D000-$DFFF CHAREN on) during reset — KERNAL does not do that.
--
-- The SuperCPU ROM (scpu64) is also not loaded. The bench drives
-- supercpu_en='1' and supercpu_rom='0' so the kickstart path is bypassed
-- entirely and BASIC/KERNAL are served normally. (When supercpu_rom='0'
-- the scpu_rom_vis flag still defaults to '1' at reset but because
-- supercpu_rom='0' feeds into the ROM mux gate, the C64 KERNAL data wins
-- at $E000.)
--
-- NB: the real system uses Intel .mif files that are baked into the
-- dprom via Altera's `ram_init_file` attribute. GHDL ignores that
-- attribute and leaves the dprom contents at 'U' until our loader fills
-- them over the c64rom handshake at reset. We could instead parse the
-- .mif files directly from C64_MiSTer/rtl/roms/std_C64.mif; see the
-- `try_load_mif_std_c64` procedure below.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.textio.all;

package rom_loader_pkg is

    type rom_bin_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- Status flags returned by the loader
    type rom_status_t is record
        found  : boolean;
        source : string (1 to 32);  -- fixed-width to keep the record simple
        bytes  : integer;
    end record;

    -- Attempt to read a 16 KB BASIC+KERNAL blob from the given path.
    -- If the file exists and is >= 16 KB, returns `found=true` and fills
    -- `image` with the first 16 KB. Otherwise returns `found=false`.
    procedure load_bin_16k (
        constant path  : in  string;
        variable image : out rom_bin_t;  -- 0..16383
        variable ok    : out boolean
    );

    -- Stock C64 std_C64.mif parser (Intel MIF format).
    -- Reads the MIF file and fills `image` with 16 KB. Returns
    -- ok=true on success, false otherwise. This lets the harness
    -- use the in-repo MIF directly without a separate .bin file.
    procedure load_mif_16k (
        constant path  : in  string;
        variable image : out rom_bin_t;
        variable ok    : out boolean
    );

    -- Minimal "idle" ROM fallback used when no real KERNAL is found.
    -- Generates a 16 KB image with:
    --   - Reset vector $FFFC/$FFFD pointing at $E000
    --   - $E000: CLD; SEI; LDA #$00; STA $0001; BRA * (spin loop)
    --     which keeps the CPU halted in a known state
    --   - BASIC pointer area ($2B/$2C, $AE/$AF etc) zero (inj_meminit
    --     fills these anyway)
    function make_fallback_rom return rom_bin_t;

    -- Convenience: try the preferred paths in order; fall back to the
    -- idle stub if none found. Returns a 16 KB image + source label.
    procedure resolve_kernal_basic (
        variable image  : out rom_bin_t;
        variable status : out rom_status_t
    );

end package;

package body rom_loader_pkg is

    procedure load_bin_16k (
        constant path  : in  string;
        variable image : out rom_bin_t;
        variable ok    : out boolean
    ) is
        type char_file_t is file of character;
        file     f       : char_file_t;
        variable ch      : character;
        variable i       : integer := 0;
        variable fstatus : file_open_status;
    begin
        ok := false;
        file_open(fstatus, f, path, READ_MODE);
        if fstatus /= OPEN_OK then
            return;
        end if;
        while not endfile(f) and i < image'length loop
            read(f, ch);
            image(i) := std_logic_vector(to_unsigned(character'pos(ch), 8));
            i := i + 1;
        end loop;
        file_close(f);
        if i >= image'length then
            ok := true;
        end if;
    end procedure;

    ------------------------------------------------------------------
    -- MIF parser
    -- Recognizes:
    --   "ADDRESS_RADIX = HEX;" / "DATA_RADIX = HEX;"
    --   "CONTENT BEGIN" / "END;"
    --   Lines of form "<hex_addr> : <hex_data>;"
    -- Ignores comments after "--" and blank lines.
    ------------------------------------------------------------------
    function hex_char_value (c : character) return integer is
    begin
        case c is
            when '0' => return 0;  when '1' => return 1;
            when '2' => return 2;  when '3' => return 3;
            when '4' => return 4;  when '5' => return 5;
            when '6' => return 6;  when '7' => return 7;
            when '8' => return 8;  when '9' => return 9;
            when 'a' | 'A' => return 10;
            when 'b' | 'B' => return 11;
            when 'c' | 'C' => return 12;
            when 'd' | 'D' => return 13;
            when 'e' | 'E' => return 14;
            when 'f' | 'F' => return 15;
            when others => return -1;
        end case;
    end function;

    procedure parse_hex (
        constant s     : in  string;
        variable pos   : inout integer;
        variable value : out integer;
        variable ok    : out boolean
    ) is
        variable v  : integer := 0;
        variable d  : integer;
        variable n  : integer := 0;
    begin
        ok := false;
        -- Skip leading whitespace
        while pos <= s'length and (s(pos) = ' ' or s(pos) = HT) loop
            pos := pos + 1;
        end loop;
        while pos <= s'length loop
            d := hex_char_value(s(pos));
            if d < 0 then exit; end if;
            v := v * 16 + d;
            n := n + 1;
            pos := pos + 1;
        end loop;
        if n > 0 then
            value := v;
            ok := true;
        else
            value := 0;
        end if;
    end procedure;

    procedure load_mif_16k (
        constant path  : in  string;
        variable image : out rom_bin_t;
        variable ok    : out boolean
    ) is
        file     f          : text;
        variable fstatus    : file_open_status;
        variable l          : line;
        variable in_content : boolean := false;
        variable s          : string (1 to 256);
        variable slen       : integer;
        variable pos        : integer;
        variable addr       : integer;
        variable data       : integer;
        variable p_ok       : boolean;
        variable found_any  : boolean := false;
        variable count      : integer := 0;
    begin
        ok := false;
        file_open(fstatus, f, path, READ_MODE);
        if fstatus /= OPEN_OK then
            return;
        end if;

        while not endfile(f) loop
            readline(f, l);
            slen := l'length;
            if slen > 256 then slen := 256; end if;
            s := (others => ' ');
            for i in 1 to slen loop
                s(i) := l(i);
            end loop;

            -- Strip comments
            for i in 1 to slen - 1 loop
                if s(i) = '-' and s(i + 1) = '-' then
                    slen := i - 1;
                    exit;
                end if;
            end loop;

            -- Look for CONTENT BEGIN / END
            if not in_content then
                for i in 1 to slen - 5 loop
                    if s(i) = 'C' and s(i + 1) = 'O' and s(i + 2) = 'N' and
                       s(i + 3) = 'T' and s(i + 4) = 'E' and s(i + 5) = 'N' then
                        in_content := true;
                        exit;
                    end if;
                end loop;
            else
                -- Check for END;
                for i in 1 to slen - 2 loop
                    if s(i) = 'E' and s(i + 1) = 'N' and s(i + 2) = 'D' then
                        in_content := false;
                        exit;
                    end if;
                end loop;

                if in_content then
                    -- Try to parse "<hex> : <hex>;"
                    pos := 1;
                    parse_hex(s(1 to slen), pos, addr, p_ok);
                    if p_ok then
                        -- Skip to ':'
                        while pos <= slen and s(pos) /= ':' loop
                            pos := pos + 1;
                        end loop;
                        if pos <= slen then
                            pos := pos + 1;  -- past ':'
                            parse_hex(s(1 to slen), pos, data, p_ok);
                            if p_ok and addr >= 0 and addr < image'length then
                                image(addr) := std_logic_vector(
                                    to_unsigned(data mod 256, 8));
                                found_any := true;
                                count := count + 1;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end loop;

        file_close(f);
        if found_any and count >= 16000 then
            ok := true;
        end if;
    end procedure;

    function make_fallback_rom return rom_bin_t is
        variable r : rom_bin_t (0 to 16383) := (others => x"EA"); -- NOP fill
    begin
        -- KERNAL lives at MIF offset $2000..$3FFF (which maps to $E000..$FFFF
        -- via fpga64_buslogic). We want a tiny reset handler at $E000 that
        -- spins forever in a known state.
        --
        -- $E000: 78      SEI
        -- $E001: D8      CLD
        -- $E002: A9 00   LDA #$00
        -- $E004: 85 01   STA $01  (all RAM)
        -- $E006: 4C 06 E0  JMP $E006  (infinite loop)
        r(16#2000#) := x"78";
        r(16#2001#) := x"D8";
        r(16#2002#) := x"A9";
        r(16#2003#) := x"00";
        r(16#2004#) := x"85";
        r(16#2005#) := x"01";
        r(16#2006#) := x"4C";
        r(16#2007#) := x"06";
        r(16#2008#) := x"E0";

        -- Reset vector at $FFFC/$FFFD points at $E000
        -- MIF addressing: $FFFC -> offset $3FFC
        r(16#3FFC#) := x"00";
        r(16#3FFD#) := x"E0";
        -- NMI vector ($FFFA/$FFFB) -> $E000 (harmless loop)
        r(16#3FFA#) := x"00";
        r(16#3FFB#) := x"E0";
        -- IRQ/BRK vector ($FFFE/$FFFF) -> $E000
        r(16#3FFE#) := x"00";
        r(16#3FFF#) := x"E0";

        return r;
    end function;

    procedure resolve_kernal_basic (
        variable image  : out rom_bin_t;
        variable status : out rom_status_t
    ) is
        variable local_image : rom_bin_t (0 to 16383);
        variable ok          : boolean;
        variable blank       : string (1 to 32) := (others => ' ');
    begin
        status.source := blank;
        status.bytes  := 16384;
        status.found  := false;

        -- 1. sim/common/roms/kernal_basic_16k.bin
        load_bin_16k("../../common/roms/kernal_basic_16k.bin", local_image, ok);
        if ok then
            status.found  := true;
            status.source(1 to 22) := "common/roms/16k_blob  ";
            image := local_image;
            return;
        end if;

        -- 2. In-repo MIF file (always present)
        load_mif_16k("../../../C64_MiSTer/rtl/roms/std_C64.mif", local_image, ok);
        if ok then
            status.found  := true;
            status.source(1 to 22) := "rtl/roms/std_C64.mif  ";
            image := local_image;
            return;
        end if;

        -- 3. dol_C64.mif as a last resort (DolphinDOS kernel)
        load_mif_16k("../../../C64_MiSTer/rtl/roms/dol_C64.mif", local_image, ok);
        if ok then
            status.found  := true;
            status.source(1 to 22) := "rtl/roms/dol_C64.mif  ";
            image := local_image;
            return;
        end if;

        -- Fallback: synthesize an idle KERNAL stub
        image := make_fallback_rom;
        status.found := false;
        status.source(1 to 22) := "fallback_idle_stub    ";
    end procedure;

end package body;
