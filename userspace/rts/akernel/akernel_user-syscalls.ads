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
   Boot_Manifest_File  : constant U64 := 1;
   Syscall_Failed      : constant U64 := U64'Last;
   Boot_EOF            : constant U64 := 256;

   Spawn_Ok               : constant U64 := 0;
   Spawn_Invalid_Program  : constant U64 := 1;
   Spawn_No_Slot          : constant U64 := 2;
   Spawn_Load_Failed      : constant U64 := 3;
   Spawn_Cap_Failed       : constant U64 := 4;
   Spawn_Scheduler_Failed : constant U64 := 5;
   Spawn_Invalid_Parent   : constant U64 := 6;

   function IRQ_Wait (Cap : U64) return U64;
   function IRQ_Ack (Cap : U64) return U64;
   function Spawn_Boot_Path
     (Path_Offset : U64;
      Path_Length : U64;
      Grant_Mask  : U64;
      Process_Cap : out U64) return U64;
   function Boot_File_Size (File_Id : U64) return U64;
   function Boot_Read_Byte
     (File_Id : U64;
      Offset  : U64) return U64;
   procedure Process_Exit;
   function Reap_Process (Process_Cap : U64) return U64;
   procedure Debug_Put (S : String);
   procedure Debug_Put_Line (S : String);
end Akernel_User.Syscalls;
