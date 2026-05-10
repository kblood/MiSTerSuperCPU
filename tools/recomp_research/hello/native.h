/*
 * native.h
 */

#ifndef _NATIVE_H_
#define _NATIVE_H_

extern int __native_start[];
extern int __native_end[];

#define _native_jump_size (256 * 2)
#define _native_jump_base (0x1000)

/* tick */
#define _native_jump_tick_install   ((unsigned int)(*((unsigned short *)(_native_jump_base + 0))))
#define _native_jump_tick_uninstall ((unsigned int)(*((unsigned short *)(_native_jump_base + 2))))
#define _native_jump_tick           ((unsigned int)(*((unsigned short *)(_native_jump_base + 4))))

typedef void (*_tick_install_t)(unsigned int cycles_per_tick);
typedef void (*_tick_uninstall_t)(void);
typedef unsigned int (*_tick_t)(void);

#define _tick_install(_cycles_per_tick) ((_tick_install_t)(_native_jump_tick_install))(_cycles_per_tick)
#define _tick_uninstall()               ((_tick_uninstall_t)(_native_jump_tick_uninstall))()
#define _tick()                         ((_tick_t)(_native_jump_tick))()

/* supercpu */
#define _native_supercpu_turbo      ((unsigned int)(*((unsigned short *)(_native_jump_base + 6))))

typedef void (*_supercpu_turbo_t)(int turbo);

#define _supercpu_turbo(_turbo)     ((_supercpu_turbo_t)(_native_supercpu_turbo))(_turbo)

/* keyboard & joystick */
#define _native_keyboard_setup      ((unsigned int)(*((unsigned short *)(_native_jump_base + 8))))
#define _native_keyboard_get        ((unsigned int)(*((unsigned short *)(_native_jump_base + 10))))
#define _native_joystick_get        ((unsigned int)(*((unsigned short *)(_native_jump_base + 12))))

typedef void (*_keyboard_setup_t)(void);
typedef unsigned int (*_keyboard_get_t)(void);
typedef unsigned int (*_joystick_get_t)(void);

#define _keyboard_setup() ((_keyboard_setup_t)(_native_keyboard_setup))()
#define _keyboard_get()   ((_keyboard_get_t)(_native_keyboard_get))()
#define _joystick_get()   ((_joystick_get_t)(_native_joystick_get))()

#endif /* _NATIVE_H_ */
