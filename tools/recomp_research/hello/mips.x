/*
 * Linker script
 */

TARGET("elf32-littlemips")
OUTPUT_ARCH("mips")

ENTRY("_start")

STARTUP(obj/start.o)

SECTIONS
{
	. = 0x00800000;
	__header_start = .;
	.scpu : { *(.scpu.header) *(.scpu.native) }
	. = ALIGN(4);
	__header_end = .;

	__text_start = .;
	.text : { *(.text) }
	. = ALIGN(4);
	__text_end = .;

	__rodata_start = .;
	.rodata : { *(.rodata) *(.rodata.*) }
	. = ALIGN(4);
	__rodata_end = .;

	__data_start = .;
	.data : { *(.data) }
	. = ALIGN(4);
	__data_end = .;

	_gp = . + 0x00008000;

	__sdata_start = .;
	.sdata : { *(.sdata) }
	. = ALIGN(4);
	__sdata_end = .;

	__sbss_start = .;
	.sbss : { *(.sbss) *(.scommon) }
	. = ALIGN(4);
	__sbss_end = .;

	__bss_start = .;
	.bss : { *(.bss) *(COMMON) }
	. = ALIGN(4);
	__bss_end = .;

	__heap_start = .;
	. = 0x00f40000;
	__heap_end = .;

	__stack_start = .;
	. = 0x00f60000;
	__stack_end = .;

	_sp = . - 0x00000010;
}
