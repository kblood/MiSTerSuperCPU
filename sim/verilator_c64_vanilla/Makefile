.PHONY: all build run run-headless run-sdl clean stage synth yosys verilate help

# ----------------------------------------------------------------------------
# Configurable build knobs (see docs/verilator_performance_optimization.md)
# ----------------------------------------------------------------------------
# FAST=1             Optimize for runtime: drop trace infra, enable -O3 -march=native.
# ENABLE_TRACE=1     Force-include --trace-fst (otherwise stripped unless FAST=0).
# JOBS ?= 12         Compile parallelism for the obj_dir sub-make.
# VL_THREADS ?= 4    Verilator --threads count.
# LTO=1              Enable link-time optimization (slower build, faster runtime).
# OBJ_DIR            Override output directory (e.g. /dev/shm/vanilla_obj).
# GENERATED_DIR      Override ghdl --synth output directory.
# USE_MOLD=0         Opt-out of mold auto-detect.
# USE_CCACHE=0       Opt-out of ccache auto-detect.
# ----------------------------------------------------------------------------

TOP := verilator_c64_vanilla_top
SCRIPT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
HOST_SRC := host/main.cpp

GENERATED_DIR ?= flow/generated
STAGE_DIR := flow/build_staging
OBJ_DIR ?= obj_dir
GEN_V := $(GENERATED_DIR)/$(TOP).v
BIN := $(OBJ_DIR)/V$(TOP)

VERILATOR ?= verilator
GHDL ?= ghdl
GHDL_BACKEND ?= gcc
PYTHON ?= python3

FAST ?= 1
JOBS ?= 12
VL_THREADS ?= 4
USE_MOLD ?= 1
USE_CCACHE ?= 1

# ----------------------------------------------------------------------------
# Toolchain auto-detection
# ----------------------------------------------------------------------------
ifeq ($(USE_CCACHE),1)
ifeq ($(shell command -v ccache >/dev/null 2>&1 && echo yes),yes)
CXX := ccache g++
endif
endif

ifeq ($(USE_MOLD),1)
ifeq ($(shell command -v mold >/dev/null 2>&1 && echo yes),yes)
LDFLAGS += -fuse-ld=mold
endif
endif

# ----------------------------------------------------------------------------
# Compile/link flags
# ----------------------------------------------------------------------------
CXXFLAGS += -std=c++17 -Wall -Wextra

ifeq ($(FAST),1)
CXXFLAGS += -O3 -march=native -mtune=native -DNDEBUG
OPT_FAST ?= -O3 -march=native -mtune=native
else
CXXFLAGS += -O2
OPT_FAST ?= -O3
endif

ifeq ($(LTO),1)
CXXFLAGS += -flto
LDFLAGS += -flto
OPT_FAST += -flto
endif

VERILATOR_FLAGS := --language 1364-2001 -Wno-fatal --x-assign fast --x-initial fast --threads $(VL_THREADS)

# Default: strip trace when FAST=1, keep it otherwise. ENABLE_TRACE=1 forces inclusion.
ifeq ($(ENABLE_TRACE),1)
VERILATOR_FLAGS += --trace-fst
else ifneq ($(FAST),1)
VERILATOR_FLAGS += --trace-fst
endif

RUN_CYCLES ?= 1000001
RUN_ROM ?= ../../C64_MiSTer/rtl/roms/std_C64.mif
RUN_PRG ?=
RUN_EXTRA ?=

ifeq ($(strip $(RUN_PRG)),)
RUN_PRG_ARGS :=
else
RUN_PRG_ARGS := --prg $(RUN_PRG)
endif

RUN_ARGS := --cycles $(RUN_CYCLES) --rom $(RUN_ROM) $(RUN_PRG_ARGS) $(RUN_EXTRA)

ifeq ($(shell pkg-config --exists sdl2 && echo yes),yes)
CXXFLAGS += $(shell pkg-config --cflags sdl2) -DHAVE_SDL2=1
LDLIBS += $(shell pkg-config --libs sdl2)
endif

CXX_EXPORT := $(if $(CXX),CXX="$(CXX)",)

all: build

help:
	@echo "Targets: build | run | run-headless | run-sdl | stage | synth | verilate | clean"
	@echo "Knobs:   FAST=1 (default) | ENABLE_TRACE=1 | JOBS=12 | VL_THREADS=4 | LTO=1"
	@echo "         OBJ_DIR=/dev/shm/... | GENERATED_DIR=/dev/shm/..."
	@echo "         USE_MOLD=0 | USE_CCACHE=0"
	@echo "Example: make FAST=1 LTO=1 JOBS=16 build"

build: $(BIN)

$(STAGE_DIR)/.stamp: flow/prepare_staging.sh ../../C64_MiSTer/rtl/fpga64_sid_iec.vhd ../../C64_MiSTer/rtl/cpu_6510.vhd
	@mkdir -p $(STAGE_DIR)
	bash flow/prepare_staging.sh
	@touch $@

stage: $(STAGE_DIR)/.stamp

$(GEN_V): $(STAGE_DIR)/.stamp $(TOP).vhd \
 ../../C64_MiSTer/rtl/mos6526.v \
 ../common/powerup/c64_powerup_init_pkg.vhd \
 ../common/memory_models/simple_sdram_model.vhd \
 ../c64_reduced_harness/stubs/fpga64_rgbcolor_stub.vhd \
 ../c64_reduced_harness/stubs/mos6526_stub.vhd \
 ../c64_reduced_harness/stubs/sid_top_stub.vhd \
 flow/postprocess_generated_verilog.py
	@mkdir -p $(GENERATED_DIR)
	GHDL_BACKEND=$(GHDL_BACKEND) $(GHDL) --synth --out=verilog --std=08 --ieee=synopsys -frelaxed \
		../../C64_MiSTer/rtl/65C816/P65816_pkg.vhd \
		../../C64_MiSTer/rtl/65C816/BCDAdder.vhd \
		../../C64_MiSTer/rtl/65C816/AddSubBCD.vhd \
		../../C64_MiSTer/rtl/65C816/ALU.vhd \
		../../C64_MiSTer/rtl/65C816/AddrGen.vhd \
		../../C64_MiSTer/rtl/65C816/MCode.vhd \
		../../C64_MiSTer/rtl/65C816/P65C816.vhd \
		../../C64_MiSTer/rtl/cpu_65c816.vhd \
		../../C64_MiSTer/rtl/t65/T65_Pack.vhd \
		../../C64_MiSTer/rtl/t65/T65_MCode.vhd \
		../../C64_MiSTer/rtl/t65/T65_ALU.vhd \
		../../C64_MiSTer/rtl/t65/T65.vhd \
		flow/build_staging/cpu_6510.vhd \
		../c64_reduced_harness/stubs/fpga64_rgbcolor_stub.vhd \
		../c64_reduced_harness/stubs/mos6526_stub.vhd \
		../c64_reduced_harness/stubs/sid_top_stub.vhd \
		../../C64_MiSTer/rtl/spram.vhd \
		../../C64_MiSTer/rtl/dprom.vhd \
		../../C64_MiSTer/rtl/bram_valid.vhd \
		../../C64_MiSTer/rtl/c64_ram64k.vhd \
		../../C64_MiSTer/rtl/cpu_cache.vhd \
		../../C64_MiSTer/rtl/fpga64_keyboard.vhd \
		../../C64_MiSTer/rtl/fpga64_buslogic.vhd \
		../../C64_MiSTer/rtl/video_vicII_656x.vhd \
		flow/build_staging/fpga64_sid_iec.vhd \
		../common/powerup/c64_powerup_init_pkg.vhd \
		../common/memory_models/simple_sdram_model.vhd \
		$(TOP).vhd \
		-e $(TOP) > $(GEN_V)
	$(PYTHON) flow/postprocess_generated_verilog.py $(GEN_V)

synth: $(GEN_V)
yosys: $(GEN_V)

$(BIN): $(GEN_V) $(HOST_SRC)
	@mkdir -p $(OBJ_DIR)
	$(VERILATOR) --cc $(abspath $(GEN_V)) --top-module $(TOP) --exe $(abspath $(HOST_SRC)) \
		--Mdir $(OBJ_DIR) \
		-CFLAGS "$(CXXFLAGS)" -LDFLAGS "$(LDLIBS) $(LDFLAGS)" $(VERILATOR_FLAGS)
	$(MAKE) -C $(OBJ_DIR) -f V$(TOP).mk OPT_FAST="$(OPT_FAST)" $(CXX_EXPORT) -j$(JOBS) V$(TOP)

verilate: $(BIN)

run: run-headless

run-headless: $(BIN)
	./$(BIN) --headless $(RUN_ARGS)

run-sdl: $(BIN)
	./$(BIN) $(RUN_ARGS)

clean:
	rm -rf $(OBJ_DIR) $(GENERATED_DIR) $(STAGE_DIR)
