with Interfaces;
with System;
with System.Storage_Elements;

package body Akernel_User.Syscalls is
   use type Interfaces.Unsigned_64;
   procedure Raw_Yield
     with Import, Convention => C, External_Name => "akernel_sys_yield";

   procedure Raw_Debug_Putchar (C : Interfaces.Unsigned_64)
     with Import,
          Convention => C,
          External_Name => "akernel_sys_debug_putchar";

   function Raw_Map_MMIO
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_map_mmio";

   function Raw_IRQ_Wait (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_irq_wait";

   function Raw_IRQ_Ack (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_irq_ack";

   function Raw_Spawn
     (Image_Cap   : U64;
      Grant_Count : U64;
      Process_Cap : System.Address) return U64
     with Import, Convention => C, External_Name => "akernel_sys_spawn";

   function Raw_Boot_File_Size (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_boot_file_size";

   function Raw_Boot_Read_Byte
     (Cap     : U64;
      Offset  : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_boot_read_byte";

   procedure Raw_Process_Exit
     with Import, Convention => C, External_Name => "akernel_sys_exit";

   function Raw_Reap_Process (Process_Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_reap_process";

   function Raw_EP_Create return U64
     with Import, Convention => C, External_Name => "akernel_sys_ep_create";

   function Raw_Mem_Alloc (Pages : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_mem_alloc";

   function Raw_Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_mem_map";

   function Raw_Mem_Unmap
     (Address_Space : U64;
      VA            : U64;
      Length        : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_mem_unmap";

   function Raw_Ntfn_Create return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_ntfn_create";

   function Raw_Ntfn_Wait (Cap : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_ntfn_wait";

   function Raw_Ntfn_Signal (Cap : U64; Bits : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_ntfn_signal";

   function Raw_Ntfn_Bind_Thread (Cap : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_ntfn_bind_thread";

   function Raw_IRQ_Bind_Ntfn
     (IRQ_Cap  : U64;
      Ntfn_Cap : U64;
      Badge    : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_irq_bind_ntfn";

   function Raw_IO_Map
     (Resource  : U64;
      Base      : U64;
      Length    : U64;
      Device_Id : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_io_map";

   function Raw_IRQ_Create (Resource : U64; Source : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_irq_create";

   function Raw_Mem_Object_PA (Cap : U64; Index : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_mem_object_pa";

   function Raw_Cap_Delete (Cap : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_cap_delete";

   function Raw_CPU_Count return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_cpu_count";

   function Raw_Cap_Mint (Source : U64; Rights_Mask : U64; Badge : U64)
                          return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_cap_mint";

   function Raw_Mem_Map_File
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Lead_In_Ptr   : System.Address) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_mem_map_file";

   function Raw_IPC_Call (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_ipc_call";

   function Raw_IPC_Recv (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_ipc_recv";

   function Raw_IPC_Reply (Cap : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_ipc_reply";

   procedure Yield is
   begin
      Raw_Yield;
   end Yield;

   function Map_MMIO
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
   is
   begin
      return Raw_Map_MMIO
        (Address_Space, Cap, VA, Offset, Length, Flags);
   end Map_MMIO;

   function IRQ_Wait (Cap : U64) return U64 is
   begin
      return Raw_IRQ_Wait (Cap);
   end IRQ_Wait;

   function IRQ_Ack (Cap : U64) return U64 is
   begin
      return Raw_IRQ_Ack (Cap);
   end IRQ_Ack;

   function Spawn
     (Image_Cap   : U64;
      Grant_Count : U64;
      Process_Cap : out U64) return U64
   is
   begin
      Process_Cap := 0;
      return Raw_Spawn
        (Image_Cap, Grant_Count, Process_Cap'Address);
   end Spawn;

   function Boot_File_Size (Cap : U64) return U64 is
   begin
      return Raw_Boot_File_Size (Cap);
   end Boot_File_Size;

   function Boot_Read_Byte
     (Cap     : U64;
      Offset  : U64) return U64
   is
   begin
      return Raw_Boot_Read_Byte (Cap, Offset);
   end Boot_Read_Byte;

   procedure Process_Exit is
   begin
      Raw_Process_Exit;
   end Process_Exit;

   function Reap_Process (Process_Cap : U64) return U64 is
   begin
      return Raw_Reap_Process (Process_Cap);
   end Reap_Process;

   function EP_Create return U64 is
   begin
      return Raw_EP_Create;
   end EP_Create;

   function Mem_Alloc (Pages : U64) return U64 is
   begin
      return Raw_Mem_Alloc (Pages);
   end Mem_Alloc;

   function Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
   is
   begin
      return Raw_Mem_Map (Address_Space, Cap, VA, Offset, Length, Flags);
   end Mem_Map;

   function Mem_Unmap
     (Address_Space : U64;
      VA            : U64;
      Length        : U64) return U64
   is
   begin
      return Raw_Mem_Unmap (Address_Space, VA, Length);
   end Mem_Unmap;

   function Ntfn_Create return U64 is
   begin
      return Raw_Ntfn_Create;
   end Ntfn_Create;

   function Ntfn_Wait (Cap : U64) return U64 is
   begin
      return Raw_Ntfn_Wait (Cap);
   end Ntfn_Wait;

   function Ntfn_Signal (Cap : U64; Bits : U64) return U64 is
   begin
      return Raw_Ntfn_Signal (Cap, Bits);
   end Ntfn_Signal;

   function Ntfn_Bind_Thread (Cap : U64) return U64 is
   begin
      return Raw_Ntfn_Bind_Thread (Cap);
   end Ntfn_Bind_Thread;

   function IRQ_Bind_Ntfn
     (IRQ_Cap  : U64;
      Ntfn_Cap : U64;
      Badge    : U64) return U64
   is
   begin
      return Raw_IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, Badge);
   end IRQ_Bind_Ntfn;

   function IO_Map
     (Resource  : U64;
      Base      : U64;
      Length    : U64;
      Device_Id : U64 := U64'Last) return U64 is
   begin
      return Raw_IO_Map (Resource, Base, Length, Device_Id);
   end IO_Map;

   function IRQ_Create (Resource : U64; Source : U64) return U64 is
   begin
      return Raw_IRQ_Create (Resource, Source);
   end IRQ_Create;

   function Mem_Object_PA (Cap : U64; Index : U64) return U64 is
   begin
      return Raw_Mem_Object_PA (Cap, Index);
   end Mem_Object_PA;

   function Cap_Delete (Cap : U64) return U64 is
   begin
      return Raw_Cap_Delete (Cap);
   end Cap_Delete;

   function CPU_Count return U64 is
   begin
      return Raw_CPU_Count;
   end CPU_Count;

   function Cap_Mint (Source : U64; Rights_Mask : U64; Badge : U64)
                      return U64 is
   begin
      return Raw_Cap_Mint (Source, Rights_Mask, Badge);
   end Cap_Mint;

   function Mem_Map_File
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Lead_In       : out U64) return U64
   is
   begin
      return Raw_Mem_Map_File
        (Address_Space, Cap, VA, Offset, Length, Lead_In'Address);
   end Mem_Map_File;

   function IPC_Call (Cap : U64) return U64 is
   begin
      return Raw_IPC_Call (Cap);
   end IPC_Call;

   function IPC_Recv (Cap : U64) return U64 is
   begin
      return Raw_IPC_Recv (Cap);
   end IPC_Recv;

   function IPC_Reply return U64 is
   begin
      return Raw_IPC_Reply (Reply_Cap_Handle);
   end IPC_Reply;

   procedure Set_Grant
     (Index       : U64;
      Source_Cap  : U64;
      Rights_Mask : U64;
      Badge       : U64)
   is
      use System.Storage_Elements;

      type Grant_Entry is record
         Source_Handle : U64;
         Rights_Mask   : U64;
         Badge         : U64;
      end record;

      type Grant_Array is array (U64 range 0 .. Max_Grants - 1)
        of Grant_Entry;

      Grants : Grant_Array
        with Volatile, Address => System'To_Address
          (Integer_Address (IPC_Buffer_VA)
           + Integer_Address (Grant_List_Offset));
   begin
      if Index >= Max_Grants then
         return;
      end if;

      Grants (Index) :=
        (Source_Handle => Source_Cap,
         Rights_Mask   => Rights_Mask,
         Badge         => Badge);
   end Set_Grant;

   function Boot_Cap (Name : String) return U64 is
      Match : Boolean;
   begin
      if Bootinfo.Magic /= Bootinfo_Magic then
         return 0;
      end if;

      for Index in Bootinfo.Entries'Range loop
         exit when U64 (Index) >= Bootinfo.Count;
         if Bootinfo.Entries (Index).Name_Length = U64 (Name'Length) then
            Match := True;
            for J in Name'Range loop
               if Bootinfo.Entries (Index).Name (J - Name'First + 1)
                 /= Name (J)
               then
                  Match := False;
                  exit;
               end if;
            end loop;

            if Match then
               return Bootinfo.Entries (Index).Handle;
            end if;
         end if;
      end loop;

      return 0;
   end Boot_Cap;

   function Boot_Cap_Rights (Name : String) return U64 is
      Match : Boolean;
   begin
      if Bootinfo.Magic /= Bootinfo_Magic then
         return 0;
      end if;

      for Index in Bootinfo.Entries'Range loop
         exit when U64 (Index) >= Bootinfo.Count;
         if Bootinfo.Entries (Index).Name_Length = U64 (Name'Length) then
            Match := True;
            for J in Name'Range loop
               if Bootinfo.Entries (Index).Name (J - Name'First + 1)
                 /= Name (J)
               then
                  Match := False;
                  exit;
               end if;
            end loop;

            if Match then
               return Bootinfo.Entries (Index).Rights_Mask;
            end if;
         end if;
      end loop;

      return 0;
   end Boot_Cap_Rights;

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

   procedure Read_Args (S : out String; Len : out Natural) is
      use System.Storage_Elements;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Page : Byte_Array (0 .. Page_Size - 1)
        with Address => To_Address (Integer_Address (Args_VA));
      Ch   : Character;
   begin
      Len := 0;
      if Mem_Map (Address_Space_Cap, Args_Handle, Args_VA, 0,
                  Page_Size, 1) /= 0
      then
         return;  --  no args page granted (or already mapped)
      end if;
      for I in Page'Range loop
         exit when Natural (Page (I)) = 0 or else Len >= S'Length;
         Ch := Character'Val (Natural (Page (I)));
         exit when Ch = Character'Val (10);
         Len := Len + 1;
         S (S'First + Len - 1) := Ch;
      end loop;
   end Read_Args;
end Akernel_User.Syscalls;
