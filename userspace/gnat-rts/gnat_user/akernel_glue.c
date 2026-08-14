/*  Akernel runtime glue (milestone 53a; slimmed in 53b): the full
 *  libgnat references a small libc surface from its C parts. 53b
 *  links newlib (-lc -lm), which provides memcpy/memset/memmove/
 *  memcmp/strcmp/strlen/malloc/free — the hand-rolled shims that
 *  used to live here were deleted (libc.a is processed before
 *  libgnat.a on the gprbuild link line, so they collided as
 *  multiple definitions). libgcc's frame-registration malloc now
 *  lands in newlib's malloc, backed by Akernel_User.Gloss's _sbrk
 *  arena at 0x5200_0000 — its own VA range, never the GNAT heap.
 *
 *  __gnat_exit carries the C exit status to the kernel's exit-code
 *  channel (exit a0 -> PCB -> reap a1); Process_Exit never returns.
 *  __gnat_getenv moved out in 53b: the vendored env.c provides it
 *  (the C environment stays empty; ENV: variables are files, m33a). */

extern void akernel_sys_exit (unsigned long long code) __attribute__((noreturn));

void
__gnat_exit (int status)
{
   akernel_sys_exit ((unsigned long long) status);
   for (;;) {}
}

/*  ZCX frame registration: libgcc's registered-object _Unwind_Find_FDE
 *  walks the list built by __register_frame. Called once from crt0
 *  before main (single static binary, no bases needed). */
extern char __EH_FRAME_BEGIN__[];
extern void __register_frame (void *begin);

void
akernel_register_frames (void)
{
   __register_frame (__EH_FRAME_BEGIN__);
}
