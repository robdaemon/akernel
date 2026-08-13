/*  Akernel runtime glue (milestone 53a): read the riscv time CSR from
 *  U-mode. The kernel sets scounteren CY|TM|IR at boot; qemu virt runs
 *  the timebase at 10 MHz. */
unsigned long long akernel_rdtime (void)
{
   unsigned long long v;
   __asm__ volatile ("csrr %0, time" : "=r" (v));
   return v;
}
