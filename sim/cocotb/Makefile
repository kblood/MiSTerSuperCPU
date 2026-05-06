# sim/cocotb/Makefile — cocotb + GHDL gcc backend driving the real
# P65C816 VHDL CPU core.
#
# Usage (from inside WSL2 with .venv active — see setup_wsl2.sh):
#   make test-smoke         — Layer 1 validation (SCPUMIPS-style copy)
#   make test-layer-a       — Layer 3 differential tester (added later)
#
# Why GHDL_BACKEND=gcc:
#   Cocotb requires VPI; only the gcc and llvm GHDL backends provide it.
#   Windows mcode GHDL is therefore unusable for cocotb. This makefile is
#   intended to be run from WSL2 Ubuntu, where `apt install ghdl-gcc`
#   provides the right binary at /usr/bin/ghdl-gcc.

SIM              := ghdl
TOPLEVEL_LANG    := vhdl
# VHDL identifiers are case-insensitive and GHDL normalizes them to
# lowercase. Cocotb VPI's `vpi_handle_by_name("P65C816")` therefore
# fails — must use lowercase here even though the entity is declared
# `entity P65C816`.
TOPLEVEL         := p65c816
COCOTB_TEST_MODULES ?= tests.test_scpumips_copy
# Backwards-compat alias: cocotb 2.x prefers COCOTB_TEST_MODULES, but
# `make sim MODULE=...` from old habit should still work.
MODULE           ?= $(COCOTB_TEST_MODULES)

# Force the gcc backend at the wrapper-script level. /usr/bin/ghdl is a
# shell script that picks the backend based on $GHDL_BACKEND (see
# `cat /usr/bin/ghdl`). The default order is mcode > gcc > llvm — that
# selects mcode, which has no VPI and crashes cocotb. Export gcc
# explicitly. `export VAR := value` is the GNU make form for exporting
# a recursively-expanded variable.
export GHDL_BACKEND := gcc

# libghdlvpi.so for the gcc backend lives here on Ubuntu noble.
# Add to runtime loader path so the simulator can dlopen it.
export LD_LIBRARY_PATH := /usr/lib/ghdl/gcc:$(LD_LIBRARY_PATH)

# Synopsys IEEE library (relaxed) matches the existing GHDL .ps1 benches.
SIM_ARGS         ?=
EXTRA_ARGS       += --std=08 --ieee=synopsys -frelaxed

# Absolute paths so this Makefile can be invoked from any cwd.
RTL_DIR := /mnt/c/LLM/C64/MiSTerSuperCPU/C64_MiSTer/rtl/65C816

VHDL_SOURCES := \
    $(RTL_DIR)/P65816_pkg.vhd \
    $(RTL_DIR)/BCDAdder.vhd \
    $(RTL_DIR)/AddSubBCD.vhd \
    $(RTL_DIR)/ALU.vhd \
    $(RTL_DIR)/AddrGen.vhd \
    $(RTL_DIR)/MCode.vhd \
    $(RTL_DIR)/P65C816.vhd

# Pull in cocotb's per-simulator make rules.
include $(shell cocotb-config --makefiles)/Makefile.sim

# Layer 1 validation entry point.
test-smoke:
	$(MAKE) sim MODULE=tests.test_scpumips_copy

# Layer 3 differential tester — runs all three tests in tests.test_diff_layer_a.
# Tests 1 and 3 require VICE; if LAYER_A_SKIP_VICE=1 (default in WSL2 where
# VICE isn't bridged), they self-skip and only Test 2 actually executes.
test-layer-a:
	$(MAKE) sim MODULE=tests.test_diff_layer_a LAYER_A_SKIP_VICE=$${LAYER_A_SKIP_VICE:-1}

# Run only the divergence-detection test (Test 2). Useful for smoke-checking
# the scoreboard without launching VICE.
test-diff-check:
	$(MAKE) sim MODULE=tests.test_diff_layer_a TESTCASE=test_layer_a_detects_divergence

# First Doom-workload probe — runs loader.prg through the VICE diff harness.
# Exploratory: emits a LAYER_A_JSON marker with MATCH or DIVERGE; does not
# assert MATCH. Requires VICE bridge open (mirrored networking).
test-doom-loader:
	$(MAKE) sim MODULE=tests.test_doom_loader_diff LAYER_A_SKIP_VICE=$${LAYER_A_SKIP_VICE:-0}

# Doom bank $20 game-code probe — first localization step into the actual
# Doom game banks (where the -9 microcode bug lives).
test-doom-bank20:
	$(MAKE) sim MODULE=tests.test_doom_bank20_diff LAYER_A_SKIP_VICE=$${LAYER_A_SKIP_VICE:-0}

# Doom mid-gameplay diff — uses VICE's full mid-gameplay snapshot
# (captured by tools/vice_dump_gameplay_state.py) to start both DUT and
# VICE at PC=$2A:$55A9 (or wherever VICE landed after warp). Steps both
# for ~5000 instructions and reports first divergence. If MATCH, the
# music_num=-9 bug is in the loader phase; if DIVERGE, it's a real CPU
# bug on a gameplay-only opcode path that the bank-$20 dispatcher walk
# didn't trigger.
test-doom-gameplay:
	$(MAKE) sim MODULE=tests.test_doom_gameplay_diff LAYER_A_SKIP_VICE=$${LAYER_A_SKIP_VICE:-0}

clean-all:
	rm -rf sim_build __pycache__ tests/__pycache__ results.xml
