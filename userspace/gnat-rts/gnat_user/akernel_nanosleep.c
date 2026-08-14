/*  Akernel runtime glue (milestone 53c): nanosleep for the vendored
 *  s-osprim (Ada `delay` statements). newlib for riscv64-elf does
 *  not provide nanosleep. No RTC exists, so sleep against the 10 MHz
 *  timebase CSR, yielding the hart between polls. */

#include <time.h>

unsigned long long akernel_rdtime (void);  /* akernel_rtclock.c */
extern void akernel_sys_yield (void);

int
nanosleep (const struct timespec *req, struct timespec *rem)
{
   unsigned long long start, now, ticks;

   (void) rem;  /*  non-restartable: no signals by design */
   if (req == 0 || (req->tv_sec == 0 && req->tv_nsec == 0))
      return 0;

   ticks = (unsigned long long) req->tv_sec * 10000000ULL
           + (unsigned long long) req->tv_nsec / 100ULL;
   start = akernel_rdtime ();
   for (;;)
     {
       now = akernel_rdtime ();
       if (now - start >= ticks)
          return 0;
       akernel_sys_yield ();
     }
}
