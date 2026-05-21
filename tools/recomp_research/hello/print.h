/*
 * print.h
 */

#ifndef _PRINT_H_
#define _PRINT_H_

extern const unsigned char ascii_to_screen[256];
extern const char key_to_ascii[64];
extern const char *key_to_string[64];

extern void print_clear(void);
extern int print_char(int x, int y, const char c);
extern int print_text(int x, int y, const char *text);
extern int print_hex(int x, int y, unsigned int hex);
extern int print_dec(int x, int y, int dec, int length, int zero_pad);

#endif /* _PRINT_H_ */
