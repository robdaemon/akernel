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

   function Raw_Spawn_Boot_Path
     (Path_Offset : U64;
      Path_Length : U64;
      Grant_Mask  : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_spawn_boot_path";

   function Raw_Boot_File_Size (File_Id : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_boot_file_size";

   function Raw_Boot_Read_Byte
     (File_Id : U64;
      Offset  : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_boot_read_byte";

   procedure Raw_Process_Exit
     with Import, Convention => C, External_Name => "akernel_sys_exit";

   function Raw_Reap_Process (Process_Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_reap_process";

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

   function Spawn_Boot_Path
     (Path_Offset : U64;
      Path_Length : U64;
      Grant_Mask  : U64) return U64
   is
   begin
      return Raw_Spawn_Boot_Path (Path_Offset, Path_Length, Grant_Mask);
   end Spawn_Boot_Path;

   function Boot_File_Size (File_Id : U64) return U64 is
   begin
      return Raw_Boot_File_Size (File_Id);
   end Boot_File_Size;

   function Boot_Read_Byte
     (File_Id : U64;
      Offset  : U64) return U64
   is
   begin
      return Raw_Boot_Read_Byte (File_Id, Offset);
   end Boot_Read_Byte;

   procedure Process_Exit is
   begin
      Raw_Process_Exit;
   end Process_Exit;

   function Reap_Process (Process_Cap : U64) return U64 is
   begin
      return Raw_Reap_Process (Process_Cap);
   end Reap_Process;

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
