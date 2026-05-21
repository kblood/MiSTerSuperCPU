/*
 * header.h
 */

#ifndef _HEADER_H_
#define _HEADER_H_

#define HEADER_MAGIC_0 (0x55504353) /* SCPU */
#define HEADER_MAGIC_1 (0x5350494d) /* MIPS */
#define HEADER_VERSION (0x00000003)

#ifndef __ASSEMBLER__

typedef struct scpu_header_s scpu_header_t;

struct scpu_header_s
{
  u32 magic_0;
  u32 magic_1;
  u32 version;
  u32 gp;
	u32 header_start;
	u32 header_end;
  u32 text_start;
  u32 text_end;
  u32 rodata_start;
  u32 rodata_end;
  u32 data_start;
  u32 data_end;
  u32 sdata_start;
  u32 sdata_end;
  u32 sbss_start;
  u32 sbss_end;
  u32 bss_start;
  u32 bss_end;
  u32 heap_start;
  u32 heap_end;
  u32 stack_start;
  u32 stack_end;
  u32 sp;
};

#endif /* __ASSEMBLER__ */

#endif /* _HEADER_H_ */
