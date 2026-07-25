with Interfaces;

package Arch.SBI is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Set_Timer (Time_Value : U64);
   function Time return U64;

   procedure Enable_Timer_Interrupts;
   procedure Enable_External_Interrupts;
   procedure Disable_Interrupts;
   procedure Wait_For_Interrupt;

   function Scause return U64;
   function Sepc return U64;
   function Stval return U64;
end Arch.SBI;
