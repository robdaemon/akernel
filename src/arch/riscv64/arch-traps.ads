with Interfaces;

package Arch.Traps is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Set_Kernel_Trap_Stack (Stack_Top : U64);

   procedure Initialize;
end Arch.Traps;
