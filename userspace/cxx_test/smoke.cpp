//  smoke.cpp — freestanding C++ smoke test (milestone 82a).
//  Compiled by the vendored xPack riscv-none-elf-g++ and linked
//  into an otherwise-Ada test program (the Ada-driven link pulls
//  the 15.3.1 newlib; this TU must not drag in libstdc++). Each
//  check maps to a feature the Haiku BFS port (M82c) relies on:
//
//    1. static constructors run via .init_array (crt0 calls
//       __libc_init_array since milestone 53b);
//    2. virtual dispatch through a vtable works (the BFS code is
//       class-heavy);
//    3. operator new/delete resolve to newlib malloc/free through
//       the gloss _sbrk (below, and again in the M82c port layer).

#include <stddef.h>

extern "C" void *malloc (size_t);
extern "C" void free (void *);

void *operator new (size_t n) { return malloc (n); }
void operator delete (void *p) noexcept { free (p); }
void operator delete (void *p, size_t) noexcept { free (p); }
void *operator new[] (size_t n) { return malloc (n); }
void operator delete[] (void *p) noexcept { free (p); }
void operator delete[] (void *p, size_t) noexcept { free (p); }

extern "C" void
__cxa_pure_virtual (void)
{
   for (;;) {
   }
}

class Shape {
public:
   virtual ~Shape () {}
   virtual int Area () const { return 0; }
};

class Square : public Shape {
public:
   explicit Square (int side) : side_ (side) {}
   int Area () const override { return side_ * side_; }

private:
   int side_;
};

//  Static constructor: must run via .init_array before main.
static int static_seed = 0;

struct Seeder {
   Seeder () { static_seed = 19; }
};

static Seeder seeder;

extern "C" int
cxx_smoke (void)
{
   if (static_seed != 19)
      return 1;                    //  static constructor never ran

   Shape *s = new Square (7);
   if (s == NULL)
      return 2;                    //  operator new failed

   const int area = s->Area ();    //  virtual dispatch
   delete s;

   if (area != 49)
      return 3;                    //  vtable wrong

   return 0;
}
