#!/usr/bin/env bash
# setup_wsl2.sh — One-time WSL2 setup for cocotb + GHDL (gcc backend).
#
# This must run inside WSL2 Ubuntu, not Windows. Windows GHDL is the
# `mcode` backend without VPI; cocotb requires VPI which only ships with
# the `gcc` or `llvm` GHDL backends. WSL2 `apt install ghdl-gcc` provides
# the right binary.
#
# Idempotent: safe to re-run. Creates ./.venv with cocotb installed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "[setup_wsl2] working dir: $HERE"

# 1. Confirm GHDL gcc backend is available (apt install ghdl-gcc).
if ! command -v ghdl-gcc >/dev/null 2>&1; then
    echo "[setup_wsl2] ERROR: ghdl-gcc not found." >&2
    echo "  Install with: sudo apt update && sudo apt install -y ghdl-gcc python3-venv build-essential" >&2
    exit 1
fi
echo "[setup_wsl2] ghdl-gcc: $(ghdl-gcc --version | head -1)"

# 2. libghdlvpi.so must exist where cocotb expects (or LD_LIBRARY_PATH set).
VPI_PATH="/usr/lib/ghdl/gcc/libghdlvpi.so"
if [[ ! -f "$VPI_PATH" ]]; then
    echo "[setup_wsl2] ERROR: $VPI_PATH not found." >&2
    echo "  Re-install: sudo apt install --reinstall ghdl-gcc" >&2
    exit 1
fi
echo "[setup_wsl2] libghdlvpi.so: OK ($VPI_PATH)"

# 3. python3-venv must be installed (Ubuntu splits it from python3 itself).
if ! python3 -m venv --help >/dev/null 2>&1; then
    echo "[setup_wsl2] ERROR: python3 -m venv not working." >&2
    echo "  Install with: sudo apt install -y python3-venv" >&2
    exit 1
fi

# 4. Create .venv and pip-install cocotb.
if [[ ! -d "$HERE/.venv" ]]; then
    echo "[setup_wsl2] creating venv at $HERE/.venv ..."
    python3 -m venv "$HERE/.venv"
fi

# Activate and install cocotb.
# shellcheck source=/dev/null
source "$HERE/.venv/bin/activate"
python -m pip install --upgrade pip >/dev/null
python -m pip install --upgrade 'cocotb>=1.9'

echo "[setup_wsl2] cocotb-config: $(cocotb-config --version)"
echo "[setup_wsl2] makefiles dir: $(cocotb-config --makefiles)"
echo "[setup_wsl2] DONE. To run tests:"
echo "    cd $HERE"
echo "    source .venv/bin/activate"
echo "    make test-smoke"
