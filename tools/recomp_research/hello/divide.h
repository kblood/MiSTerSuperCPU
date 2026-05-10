/*
 * divide.h
 */

#ifndef _DIVIDE_H_
#define _DIVIDE_H_

/* setup */
extern void divide_setup(unsigned int base);

/* 64bit divide */
extern unsigned long long divide_u64(unsigned long long dividend, unsigned long long divisor);
extern signed long long divide_s64(signed long long dividend, signed long long divisor);

/* 16.16 fixed point divide */
extern unsigned int divide_fixed_u(unsigned int dividend, unsigned int divisor);
extern signed int divide_fixed_s(signed int dividend, signed int divisor);

#endif /* _DIVIDE_H_ */
