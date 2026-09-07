/*  Milestone 72a: lwIP NO_SYS system port.
 *
 *  With NO_SYS=1 lwIP needs exactly one thing from the OS: a
 *  millisecond clock for its timeout list. aegir's time base is a
 *  10 MHz read-time counter (Tick_Hz), so ms = ticks / 10^4. The
 *  counter starts at boot, which is also the epoch lwIP wants. */

#include "lwip/opt.h"
#include "lwip/sys.h"

extern unsigned long long aegir_rdtime (void);

u32_t
sys_now (void)
{
   return (u32_t) (aegir_rdtime () / 10000ULL);
}
