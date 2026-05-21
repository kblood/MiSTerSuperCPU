/*
 * syscall.h
 */

#ifndef _SYSCALL_H_
#define _SYSCALL_H_

extern int __syscall_start[];
extern int __syscall_end[];

#define _syscall_jump_size (256 * 4)
#define _syscall_jump_base (0x00040000)

/* recomp */
#define _syscall_mips_recomp_no_header (*((unsigned int *)(_syscall_jump_base + 0)))
#define _syscall_mips_recomp           (*((unsigned int *)(_syscall_jump_base + 4)))

typedef int (*_mips_recomp_no_header_t)(unsigned char *base, unsigned int src_offset, unsigned int dst_offset, unsigned int src_bytes);
typedef int (*_mips_recomp_t)(unsigned char *base, unsigned int src_offset, unsigned int dst_offset, int execute);

#define _mips_recomp_no_header(a...) ((_mips_recomp_no_header_t)(_syscall_mips_recomp_no_header))(a)
#define _mips_recomp(a...)           ((_mips_recomp_t)(_syscall_mips_recomp))(a)

#endif /* _SYSCALL_H_ */
