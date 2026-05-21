#
# Makefile
#

CROSS=mipsel-unknown-elf-

MKDIR=mkdir -p
CP=cp --remove-destination -p
CPR=$(CP) -r
RM=rm -rf

# disable GP optimizations
#GP_OPT=-mno-gpopt -G0

# enable GP optimizations
GP_OPT=-mgpopt -G65536 # -mno-local-sdata -mno-extern-sdata

CC=$(CROSS)gcc
DEFS=-DLSB_FIRST -DBASE_POINTER_T_SIZE=4 -DBUILDCPU_MIPS
OPTS=-march=r3000 -mno-check-zero-division -msoft-float $(GP_OPT) \
-fomit-frame-pointer -O3 -I. -Wall -Werror -fno-builtin -nostdlib
CFLAGS=$(DEFS) -Werror -Wall -Wextra -Wundef -Wsign-compare -Wmissing-prototypes \
-Wmissing-declarations -Wwrite-strings $(OPTS) -Wa,-L # -ggdb3 -Wshadow
LDFLAGS=-T mips.x
AS=$(CROSS)as
LD=$(CROSS)ld
AR=$(CROSS)ar
RANLIB=$(CROSS)ranlib
LIBS=

OBJPATH=obj
BINPATH=bin

PATHS=$(BINPATH) $(OBJPATH)

OBJ_native=$(addprefix $(OBJPATH)/, divide_setup.o divide_u64.o divide_s64.o divide_fixed_u.o divide_fixed_s.o) \
$(addprefix $(OBJPATH)/, multiply_setup.o multiply_u32.o multiply_s32.o multiply_fixed_u.o multiply_fixed_s.o)

OBJ_hello=$(addprefix $(OBJPATH)/, native_mips.o print.o main.o) $(OBJ_native)

BINFILES=$(addprefix $(BINPATH)/, hello.bin)

# make rules
all: default

default: $(PATHS) $(BINFILES)

define BIN_template
$(2): $(OBJBASE) $(OBJCOMMON) $$(OBJ_$(1)) $(OBJPATH)/header.o $(OBJPATH)/start.o
	$(LD) $(LDFLAGS) -o $(2) $(OBJBASE) $(OBJCOMMON) $$(OBJ_$(1)) $(OBJPATH)/header.o $(LIBS)
$(3): $(2)
	$(CROSS)objcopy -O binary $(2) $(3)
	$(CROSS)objdump -t $(2) | sort > $(3).syms.txt
endef

$(eval $(call BIN_template,hello,bin/hello.elf,bin/hello.bin))

define DIR_template
$(1):
	$(MKDIR) $(1)
endef

$(foreach path,$(PATHS), \
	$(eval $(call DIR_template,$(path))) \
)

define NATIVE_template
$(patsubst %.o,%_.o,$(1)): $(patsubst $(OBJPATH)/%.o,%.s,$(1))
	64tass.exe -x -b $(patsubst $(OBJPATH)/%.o,%.s,$(1)) -o $(patsubst %.o,%_.o,$(1)) -L $(patsubst %.o,%_.o,$(1)).txt
$(1): $(patsubst %.o,%_.o,$(1))
	echo -e ".section .scpu.native, \"a\"\n.global "$(patsubst $(OBJPATH)/%.o,%,$(1))"\n.balign 4\n"$(patsubst $(OBJPATH)/%.o,%,$(1))":\n.incbin \""$(patsubst %.o,%_.o,$(1))"\"" > $(patsubst %.o,%_.s,$(1))
	$(CC) $(CFLAGS) -x assembler-with-cpp -c $(patsubst %.o,%_.s,$(1)) -o $(1) -Wa,-aln=$(1).txt
endef

$(foreach n,$(OBJ_native), \
	$(eval $(call NATIVE_template,$(n))) \
)

$(OBJPATH)/%.o: %.c
	$(CC) $(CFLAGS) -S $< -o $@.s
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJPATH)/%.o: %.s
	$(CC) $(CFLAGS) -x assembler-with-cpp -c $< -o $@ -Wa,-aln=$@.txt

$(OBJPATH)/native.o: native.s
	64tass.exe -x -b $< -o $@ -L $@.txt

$(OBJPATH)/native_mips.o: $(OBJPATH)/native.o
	echo -e ".data\n.global __native_start\n.global __native_end\n.balign 4\n__native_start:\n.incbin \""$<"\"\n__native_end:" > obj/native_mips.s
	$(CC) $(CFLAGS) -x assembler-with-cpp -c obj/native_mips.s -o $@ -Wa,-aln=$@.txt

clean:
	$(RM) obj/*
	$(RM) bin/*

rebuild: clean default

$(OBJ_hello) $(OBJPATH)/header.o $(OBJPATH)/start.o: \
$(wildcard *.h)
