/*  Milestone 72a: compiler/platform port header for lwIP.
 *
 *  riscv64 is little-endian; newlib provides stdint/inttypes/stdio.
 *  Diagnostics ride newlib printf, which the m53b gloss layer routes
 *  to fd 1 (the console) — an lwIP assertion therefore shows up on
 *  the serial log and wedges netserv loudly instead of corrupting
 *  state silently. */

#ifndef AKERNEL_CC_H
#define AKERNEL_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>

#define BYTE_ORDER                      LITTLE_ENDIAN

/*  newlib's <limits.h> does not define SSIZE_MAX in the default
 *  feature set, which would send arch.h down its compatibility
 *  branch (typedef int ssize_t) and clash with newlib's long
 *  ssize_t from <stdio.h>. Defining it here makes arch.h include
 *  <unistd.h> and take the system type instead. */
#ifndef SSIZE_MAX
#define SSIZE_MAX                       LONG_MAX
#endif

#define LWIP_PLATFORM_DIAG(x)           do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x)         do { \
   printf ("lwIP assert: %s at %s:%d\n", x, __FILE__, __LINE__); \
   for (;;) { } \
} while (0)

/*  arch.h defaults (gcc packed-attribute spellings, <stdint.h>
 *  types, <inttypes.h> format macros) are all correct for this
 *  toolchain — nothing else to override. */

#endif /* AKERNEL_CC_H */
