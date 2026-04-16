.PHONY: all build run run-headless run-sdl clean stage synth yosys verilate

TOP := verilator_c64_top
SCRIPT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
HOST_SRC := host/main.cpp
GENERATED_DIR := flow/generated
STAGE_DIR := flow/build_staging
GEN_V := $(GENERATED_DIR)/$(TOP).v
BIN := obj_dir/V$(TOP)
VERILATOR ?= verilator
GHDL ?= ghdl
GHDL_BACKEND ?= gcc
PYTHON ?= python3
CXXFLAGS += -std=c++17 -O2 -Wall -Wextra
VERILATOR_FLAGS := --language 1364-2001 -Wno-fatal --x-assign fast --x-initial fast --trace-fst
RUN_CYCLES ?= 1000001
RUN_ROM ?= ../../C64_MiSTer/rtl/roms/std_C64.mif
RUN_PRG ?=

ifeq ($(strip $(RUN_PRG)),)
RUN_PRG_ARGS :=
else
RUN_PRG_ARGS := --prg $(RUN_PRG)
endif

RUN_ARGS := --cycles $(RUN_CYCLES) --rom $(RUN_ROM) $(RUN_PRG_ARGS)

ifeq ($(shell pkg-config --exists sdl2 && echo yes),yes)
CXXFLAGS += $(shell pkg-config --cflags sdl2) -DHAVE_SDL2=1
LDLIBS += $(shell pkg-config --libs sdl2)
endif

all: build

build: $(BIN)

$(STAGE_DIR)/.stamp: flow/prepare_staging.sh ../../C64_MiSTer/rtl/fpga64_sid_iec.vhd
	@mkdir -p $(STAGE_DIR)
	bash flow/prepare_staging.sh
	@touch $@

stage: $(STAGE_DIR)/.stamp

$(GEN_V): $(STAGE_DIR)/.stamp verilator_c64_top.vhd \
 ../common/memory_models/simple_sdram_model.vhd \
 ../c64_reduced_harness/stubs/cpu_6510_stub.vhd \
 ../c64_reduced_harness/stubs/fpga64_rgbcolor_stub.vhd \
 ../c64_reduced_harness/stubs/mos6526_stub.vhd \
 ../c64_reduced_harness/stubs/sid_top_stub.vhd
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
		../c64_reduced_harness/stubs/cpu_6510_stub.vhd \
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
		../common/memory_models/simple_sdram_model.vhd \
		verilator_c64_top.vhd \
		-e $(TOP) > $(GEN_V)
	perl -0pi -e 's@/\*.*?\*/@@gs' $(GEN_V)

synth: $(GEN_V)
yosys: $(GEN_V)

$(BIN): $(GEN_V) $(HOST_SRC)
	$(VERILATOR) --cc $(GEN_V) --top-module $(TOP) --exe $(HOST_SRC) \
		-CFLAGS "$(CXXFLAGS)" -LDFLAGS "$(LDLIBS)" $(VERILATOR_FLAGS)
	$(MAKE) -C obj_dir -f V$(TOP).mk V$(TOP)

verilate: $(BIN)

run: run-headless

run-headless: $(BIN)
	./$(BIN) --headless $(RUN_ARGS)

run-sdl: $(BIN)
	./$(BIN) $(RUN_ARGS)

clean:
	rm -rf obj_dir $(GENERATED_DIR) $(STAGE_DIR)
