with Interfaces;

package Akernel_User.Syscalls is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Yield;
   function Map_MMIO
     (Cap    : U64;
      VA     : U64;
      Offset : U64;
      Length : U64;
      Flags  : U64) return U64;
   UART_MMIO_Grant_Bit : constant U64 := 1;
   UART_IRQ_Grant_Bit  : constant U64 := 2;

   function IRQ_Wait (Cap : U64) return U64;
   function IRQ_Ack (Cap : U64) return U64;
   function Spawn_Program
     (Program_Id : U64;
      Grant_Mask : U64) return U64;
   function Exec_Serial return U64;
   procedure Debug_Put (S : String);
   procedure Debug_Put_Line (S : String);
end Akernel_User.Syscalls;
