/*
 * mips.h
 */

#ifndef _MIPS_H_
#define _MIPS_H_

extern int _gp[];
extern int __header_start[];
extern int __header_end[];
extern int __text_start[];
extern int __text_end[];
extern int __rodata_start[];
extern int __rodata_end[];
extern int __data_start[];
extern int __data_end[];
extern int __sdata_start[];
extern int __sdata_end[];
extern int __sbss_start[];
extern int __sbss_end[];
extern int __bss_start[];
extern int __bss_end[];
extern int __heap_start[];
extern int __heap_end[];
extern int __stack_start[];
extern int __stack_end[];
extern int _sp[];

#endif /* _MIPS_H_ */
