	#include "header.h"

.section .scpu.header, "a"
.global header
.balign 4
header:
	.word HEADER_MAGIC_0
	.word HEADER_MAGIC_1
	.word HEADER_VERSION
	.word _gp
	.word __header_start
	.word __header_end
	.word __text_start
	.word __text_end
	.word __rodata_start
	.word __rodata_end
	.word __data_start
	.word __data_end
	.word __sdata_start
	.word __sdata_end
	.word __sbss_start
	.word __sbss_end
	.word __bss_start
	.word __bss_end
	.word __heap_start
	.word __heap_end
	.word __stack_start
	.word __stack_end
	.word _sp
