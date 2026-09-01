with Interfaces.C;
with Akernel_User.Console;
with Akernel_User.Syscalls;

--  Cxx_Test (milestone 82a): toolchain gate for the Haiku BFS
--  vendoring (M82). Proves a freestanding C++ translation unit
--  compiled by the vendored xPack riscv-none-elf-g++ links and
--  runs inside an akernel program: static constructors through
--  .init_array, vtable dispatch, and operator new/delete backed by
--  newlib malloc. If this program fails, M82c does not start.
--
--  Grant layout (manifest "program 16 Tests/Cxx_Test console"):
--  1 = console Send.

procedure Cxx_Test is
   use type Interfaces.C.int;

   package Console  renames Akernel_User.Console;
   package Syscalls renames Akernel_User.Syscalls;

   function Cxx_Smoke return Interfaces.C.int
     with Import, Convention => C, External_Name => "cxx_smoke";

   Rc : constant Interfaces.C.int := Cxx_Smoke;
begin
   if Rc = 0 then
      Console.Put_Line ("PASS cxx smoke: static ctor + vtable + new/delete");
      Console.Put_Line ("PASS cxx_test");
      Syscalls.Process_Exit (0);
   else
      Console.Put_Line ("FAIL cxx smoke: static ctor + vtable + new/delete");
      Console.Put_Line ("FAIL cxx_test");
      Syscalls.Process_Exit (1);
   end if;
end Cxx_Test;
