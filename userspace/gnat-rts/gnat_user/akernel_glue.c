/*  Akernel runtime glue (milestone 53a): the full libgnat references a
 *  small libc surface from its C parts (raise-gcc.c, traceback code).
 *  53b links newlib and drops the string/memory functions; __gnat_exit
 *  and __gnat_getenv stay (they are GNAT hooks, not libc).
 *
 *  __gnat_exit carries the C exit status to the kernel's exit-code
 *  channel (exit a0 -> PCB -> reap a1); Process_Exit never returns. */

extern void akernel_sys_exit (unsigned long long code) __attribute__((noreturn));

void
__gnat_exit (int status)
{
   akernel_sys_exit ((unsigned long long) status);
   for (;;) {}
}

char *
__gnat_getenv (const char *name)
{
   (void) name;
   return 0;  /* no C environment; ENV: variables are files (m33a) */
}

/*  memcpy/memset come from the akernel RTS lib's runtime_stubs
 *  (they predate the full libgnat); the rest lives here. */

void *
memmove (void *dest, const void *src, unsigned long n)
{
   unsigned char *d = dest;
   const unsigned char *s = src;
   unsigned long i;
   if (d < s)
     for (i = 0; i < n; i++)
       d[i] = s[i];
   else
     for (i = n; i > 0; i--)
       d[i - 1] = s[i - 1];
   return dest;
}

int
memcmp (const void *s1, const void *s2, unsigned long n)
{
   const unsigned char *a = s1, *b = s2;
   unsigned long i;
   for (i = 0; i < n; i++)
     if (a[i] != b[i])
       return (int) a[i] - (int) b[i];
   return 0;
}

int
strcmp (const char *s1, const char *s2)
{
   while (*s1 && *s1 == *s2)
     {
       s1++;
       s2++;
     }
   return (int) (unsigned char) *s1 - (int) (unsigned char) *s2;
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

/*  libgcc's frame registration allocates its object nodes and reads
 *  augmentation strings. Route its libc wants at the GNAT heap. */
extern void *__gnat_malloc (unsigned long long);
extern void __gnat_free (void *);

void *
malloc (unsigned long long n)
{
   return __gnat_malloc (n);
}

void
free (void *p)
{
   __gnat_free (p);
}

unsigned long
strlen (const char *s)
{
   const char *p = s;
   while (*p)
     p++;
   return (unsigned long) (p - s);
}
