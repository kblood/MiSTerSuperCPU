/*
 * multiply.h
 */

#ifndef _MULTIPLY_H_
#define _MULTIPLY_H_

/* setup */
extern void multiply_setup(unsigned int base);

/* 32bit multiply */
extern unsigned long long multiply_u32(unsigned int multiplicand, unsigned int multiplier);
extern signed long long multiply_s32(signed int multiplicand, signed int multiplier);

/* 16.16 fixed point multiply */
extern unsigned int multiply_fixed_u(unsigned int multiplicand, unsigned int multiplier);
extern signed int multiply_fixed_s(signed int multiplicand, signed int multiplier);

#endif /* _MULTIPLY_H_ */
