#!/usr/bin/env bash
# c64_ram64k RAW-hazard regression: verifies the cycle-N+1 write-data forward
# in c64_ram64k.vhd that fixes Asterix decompressor hangs (commit b267455).
set -euo pipefail

stop_time="${1:-20us}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
rtl="$repo_root/C64_MiSTer/rtl"
work_dir="$script_dir/work"
mkdir -p "$work_dir"

# Static structural check: the explicit a_din_d1 bypass mux MUST be present
# in c64_ram64k.vhd. GHDL's behavioral simulation cannot detect its removal
# (write-first VHDL semantics), but the M10K hazard on hardware needs it.
# Match a non-commented line that drives a_dout from a_din_d1 gated by a_we_d1.
ram_src="$rtl/c64_ram64k.vhd"
bypass_regex='^[[:space:]]*a_dout[[:space:]]*<=[[:space:]]*a_din_d1[[:space:]]+when[[:space:]]+a_we_d1'
if ! grep -E "$bypass_regex" "$ram_src" >/dev/null; then
    echo "FAIL: c64_ram64k.vhd is missing the M10K RAW-hazard bypass mux." >&2
    echo "      Expected an uncommented assignment matching: $bypass_regex" >&2
    echo "      This is the fix from commit b267455 (Asterix title screen)." >&2
    exit 1
fi
echo "structural check: bypass mux present in c64_ram64k.vhd"

ghdl=$(command -v ghdl || true)
if [[ -z "$ghdl" ]]; then
    echo "ghdl not found in PATH" >&2
    exit 1
fi

ghdl_flags=(--std=08 --ieee=synopsys -frelaxed "--workdir=$work_dir")
sources=(
    "$rtl/c64_ram64k.vhd"
    "$script_dir/c64_ram64k_raw_tb.vhd"
)

cd "$work_dir"
for s in "${sources[@]}"; do
    "$ghdl" -a "${ghdl_flags[@]}" "$s"
done
"$ghdl" -e "${ghdl_flags[@]}" c64_ram64k_raw_tb

log="$work_dir/c64_ram64k_raw.log"
"$ghdl" -r "${ghdl_flags[@]}" c64_ram64k_raw_tb --stop-time="$stop_time" 2>&1 | tee "$log"
echo
echo "log: $log"
