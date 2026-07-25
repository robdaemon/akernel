with Interfaces;

package body Akernel_User.Syscalls is
   use type Interfaces.Unsigned_64;
   procedure Raw_Yield
     with Import, Convention => C, External_Name => "akernel_sys_yield";

   procedure Raw_Debug_Putchar (C : Interfaces.Unsigned_64)
     with Import,
          Convention => C,
          External_Name => "akernel_sys_debug_putchar";

   function Raw_Map_MMIO
     (Cap    : U64;
      VA     : U64;
      Offset : U64;
      Length : U64;
      Flags  : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_map_mmio";

   function Raw_IRQ_Wait (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_irq_wait";

   function Raw_IRQ_Ack (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_irq_ack";

   function Raw_Spawn_Program
     (Program_Id : U64;
      Grant_Mask : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_spawn_program";

   procedure Yield is
   begin
      Raw_Yield;
   end Yield;

   function Map_MMIO
     (Cap    : U64;
      VA     : U64;
      Offset : U64;
      Length : U64;
      Flags  : U64) return U64
   is
   begin
      return Raw_Map_MMIO (Cap, VA, Offset, Length, Flags);
   end Map_MMIO;

   function IRQ_Wait (Cap : U64) return U64 is
   begin
      return Raw_IRQ_Wait (Cap);
   end IRQ_Wait;

   function IRQ_Ack (Cap : U64) return U64 is
   begin
      return Raw_IRQ_Ack (Cap);
   end IRQ_Ack;

   function Spawn_Program
     (Program_Id : U64;
      Grant_Mask : U64) return U64
   is
   begin
      return Raw_Spawn_Program (Program_Id, Grant_Mask);
   end Spawn_Program;

   function Exec_Serial return U64 is
   begin
      return Spawn_Program
        (1, UART_MMIO_Grant_Bit or UART_IRQ_Grant_Bit);
   end Exec_Serial;

   procedure Debug_Put (S : String) is
   begin
      for C of S loop
         Raw_Debug_Putchar (Character'Pos (C));
      end loop;
   end Debug_Put;

   procedure Debug_Put_Line (S : String) is
   begin
      Debug_Put (S);
      Raw_Debug_Putchar (Character'Pos (Character'Val (10)));
   end Debug_Put_Line;
end Akernel_User.Syscalls;
