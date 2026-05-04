#ifndef CELMTERM_SHIM_H
#define CELMTERM_SHIM_H

#include <stdint.h>

/* Variadic ioctl(2) can't be called directly from Swift on arm64 because
   the Apple ABI uses different calling conventions for variadic and
   non-variadic functions. This shim wraps TIOCGWINSZ in a fixed-arity
   function so Swift can call it safely.

   Returns 0 on success and writes the terminal dimensions; returns -1
   on failure with errno set by the underlying ioctl. */
int elmterm_get_winsize(int fd, uint16_t *rows, uint16_t *cols);

#endif
