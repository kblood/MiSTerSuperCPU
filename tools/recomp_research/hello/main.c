/*
 * main.c
 */

#include "print.h"
#include "native.h"
#include "divide.h"
#include "multiply.h"
#include "mips.h"

static const char text[] = "HELLO WORLD! Hello World! hello world!";

static void relocate_native(void)
{
  unsigned int *dst = (unsigned int *)_native_jump_base;
  unsigned int x;

  // relocate
  for (x = (unsigned int)__native_start; x < (unsigned int)__native_end; x += 4)
  {
    *dst++ = *((unsigned int *)x);
  }
}

int main(void)
{
  unsigned int x, ypos, xpos;

  relocate_native();

  multiply_setup(0x00200000);

  _supercpu_turbo(1);

  print_clear();

  print_text(0, 0, text);

  print_hex(0, 2, 0x01234567);
  print_hex(0, 3, 0x89abcdef);

  // 123 * 232 = 28536 << 16 = 1870135296
  // 232 << 16 = 15204352
  //x = divide_fixed_u(1870135296L, 15204352L); // 123 << 16 = 8060928
  //x = divide_u64(61725000000000LL, 5000000000LL); // 12345
  //x = multiply_u32(123, 232);
  //x = multiply_u32(x, 65536);
  x = multiply_fixed_u(123 * 65536, 232 * 65536); // 1870135296
  print_dec(11, 2, x, 11, 0);

  // 321 * -99 = -31779 << 16 = -2082668544
  // -99 << 16 = -6488064
  //x = divide_fixed_s(-2082668544L, -6488064); // 321 << 16 = 21037056
  //x = divide_s64(-339450000000000LL, -5000000000LL); // 67890
  //x = multiply_s32(321, -99);
  //x = multiply_s32(x, 65536);
  x = multiply_fixed_s(321 * 65536, -99 * 65536); // -2082668544
  print_dec(11, 3, x, 11, 1);

  print_text(0, 5, "ASCII");
  print_text(0, 5 + 10, "SCREEN");

  unsigned char *dst = (unsigned char *)1024;

  ypos = 6;
  xpos = 0;
  for (x = 0; x < 256; x++)
  {
    dst[((ypos + 10) * 40) + xpos] = x;
    print_char(xpos, ypos, x);
    xpos++;
    if (xpos == 32)
    {
      xpos = 0;
      ypos++;
    }
  }

  // PAL  =  985248 Hz = ( 985248 / 100) - 1 = 9851
  // NTSC = 1022727 Hz = (1022727 / 100) - 1 = 10226

  _tick_install((985248/100)-1);
  _keyboard_setup();

  for (;;)
  {
    unsigned int t = _tick();
    print_text(23, 2, "TICKS: ");
    print_hex(30, 2, t);

    unsigned int seconds = (t / 100);
    unsigned int decimals = (t % 100);
    print_text(23, 3, "SECS : ");
    int x = print_dec(30, 3, seconds, 0, 0);
    x = print_char(x, 3, '.');
    x = print_dec(x, 3, decimals, 2, 1);

    unsigned char key = _keyboard_get();
    print_text(23, 4, "KEY  : ");
    if (key == 0xff)
    {
      print_text(30, 4, "N/A       ");
    }
    else
    {
      print_char(30, 4, key_to_ascii[key]);
      print_char(31, 4, ' ');
      print_text(32, 4, key_to_string[key]);
    }

    unsigned char joy = _joystick_get();
    print_text(23, 5, "JOY  : ");
    print_char(30, 5, (joy & 0x01) ? 'U' : ' ');
    print_char(31, 5, (joy & 0x02) ? 'D' : ' ');
    print_char(32, 5, (joy & 0x04) ? 'L' : ' ');
    print_char(33, 5, (joy & 0x08) ? 'R' : ' ');
    print_char(34, 5, (joy & 0x10) ? 'F' : ' ');
  }

  _tick_uninstall();

  return 0;
}
