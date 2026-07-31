with Interfaces;
with System;
with System.Storage_Elements;

package Akernel_User.Syscalls is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Yield;
   Address_Space_Cap : constant U64 := 255;

   function Map_MMIO
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64;
   UART_MMIO_Grant_Bit : constant U64 := 1;
   UART_IRQ_Grant_Bit  : constant U64 := 2;
   Syscall_Failed      : constant U64 := U64'Last;
   Boot_EOF            : constant U64 := 256;

   --  Rights-mask bits for spawn grant lists (kernel encoding:
   --  Read = bit 0 .. Manage = bit 9).
   Right_Read     : constant U64 := 1;
   Right_Write    : constant U64 := 2;
   Right_Execute  : constant U64 := 4;
   Right_Map      : constant U64 := 8;
   Right_Send     : constant U64 := 16;
   Right_Receive  : constant U64 := 32;
   Right_Wait     : constant U64 := 64;
   Right_Ack      : constant U64 := 128;
   Right_Transfer : constant U64 := 256;
   Right_Manage   : constant U64 := 512;

   Spawn_Ok               : constant U64 := 0;
   Spawn_Invalid_Program  : constant U64 := 1;
   Spawn_No_Slot          : constant U64 := 2;
   Spawn_Load_Failed      : constant U64 := 3;
   Spawn_Cap_Failed       : constant U64 := 4;
   Spawn_Scheduler_Failed : constant U64 := 5;
   Spawn_Invalid_Parent   : constant U64 := 6;

   function IRQ_Wait (Cap : U64) return U64;
   function IRQ_Ack (Cap : U64) return U64;
   --  Spawn ABI v2: Image_Cap is a Boot_File_Object cap (Read +
   --  Execute rights); grant entries are in the IPC buffer.
   function Spawn
     (Image_Cap   : U64;
      Grant_Count : U64;
      Process_Cap : out U64) return U64;
   --  Cap-based boot byte API: Cap must be a Boot_File_Object cap
   --  with the Read right.
   function Boot_File_Size (Cap : U64) return U64;
   function Boot_Read_Byte
     (Cap     : U64;
      Offset  : U64) return U64;
   procedure Process_Exit;
   function Reap_Process (Process_Cap : U64) return U64;
   function EP_Create return U64;

   --  Memory objects (PMM-backed frame bundles, refcounted).
   --  Mem_Alloc returns a cap handle (Map+Read+Write+Transfer+
   --  Manage) or Syscall_Failed. Mem_Map/Mem_Unmap map the object's
   --  frames as borrowed user pages (frames stay object-owned);
   --  Flags bit 0 = read, bit 1 = write (write implies read).
   --  Return 0 on success, 1 on failure.
   function Mem_Alloc (Pages : U64) return U64;
   function Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64;
   function Mem_Unmap
     (Address_Space : U64;
      VA            : U64;
      Length        : U64) return U64;

   --  Notification objects (docs/IPC.md): a word of pending signal
   --  bits with an optional bound thread. Ntfn_Create returns a cap
   --  handle (Wait+Write+Manage) or Syscall_Failed. Ntfn_Wait
   --  blocks until bits are pending and returns them (consumed),
   --  Syscall_Failed on a bad cap. A thread binds one notification
   --  to itself (Ntfn_Bind_Thread, Manage right); IPC_Recv then
   --  checks it before blocking and signals can wake a blocked
   --  receiver with a synthetic message (Label = Notification_Label,
   --  word 0 = bits). IRQ_Bind_Ntfn makes an IRQ line signal the
   --  notification with Badge when it fires (IRQ cap Ack right,
   --  notification Write right).
   Notification_Label : constant U64 := U64'Last;

   function Ntfn_Create return U64;
   function Ntfn_Wait (Cap : U64) return U64;
   function Ntfn_Signal (Cap : U64; Bits : U64) return U64;
   function Ntfn_Bind_Thread (Cap : U64) return U64;
   function IRQ_Bind_Ntfn
     (IRQ_Cap  : U64;
      Ntfn_Cap : U64;
      Badge    : U64) return U64;

   --  Boot files as memory objects: maps a Boot_File_Object cap's
   --  frames read-only and borrowed. File data need not start on a
   --  page boundary; Lead_In returns the byte offset of the file
   --  start (plus Offset) within the first mapped page.
   function Mem_Map_File
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Lead_In       : out U64) return U64;

   Mem_Max_Pages : constant U64 := 64;
   Page_Size     : constant U64 := 4096;
   function IPC_Call (Cap : U64) return U64;
   function IPC_Recv (Cap : U64) return U64;
   function IPC_Reply return U64;

   Reply_Cap_Handle : constant U64 := 254;
   IPC_Buffer_VA    : constant U64 := 16#6FFF_0000#;
   IPC_Ok              : constant U64 := 0;
   IPC_Invalid         : constant U64 := 1;
   IPC_Transfer_Failed : constant U64 := 2;
   IPC_Endpoint_Gone   : constant U64 := 3;
   IPC_Reply_Gone      : constant U64 := 4;

   --  96-byte IPC message in this thread's buffer page.
   type IPC_Word_Array is array (0 .. 5) of U64;
   type IPC_Cap_Array is array (0 .. 3) of U64;
   type IPC_Message is record
      Label : U64;
      Words : IPC_Word_Array;
      Caps  : IPC_Cap_Array;
      Badge : U64;
   end record;

   Message : IPC_Message
     with Volatile, Address =>
       System'To_Address (System.Storage_Elements.Integer_Address
         (IPC_Buffer_VA));

   --  Spawn grant list: up to Max_Grants entries of (source handle,
   --  rights mask, badge) written into this thread's buffer page at
   --  Grant_List_Offset before calling Spawn_Boot_Path. The child
   --  receives the caps at handles 1..Grant_Count in list order.
   Grant_List_Offset : constant U64 := 128;
   Max_Grants        : constant U64 := 32;
   procedure Set_Grant
     (Index       : U64;
      Source_Cap  : U64;
      Rights_Mask : U64;
      Badge       : U64);

   --  Bootinfo page (init only): read-only kernel-written table of
   --  (handle, kind, rights mask, name) entries for every cap the
   --  kernel handed init at boot. Kind values match the kernel
   --  Object_Kind enumeration positions.
   Bootinfo_VA    : constant U64 := 16#6FFE_0000#;
   Bootinfo_Magic : constant U64 := 16#4B41_494E_464F_3031#;

   Kind_IRQ       : constant U64 := 7;
   Kind_MMIO      : constant U64 := 8;
   Kind_Boot_File : constant U64 := 11;
   Kind_Memory    : constant U64 := 12;

   Bootinfo_Max_Name : constant := 32;
   type Bootinfo_Name is array (1 .. Bootinfo_Max_Name) of Character;

   type Bootinfo_Entry is record
      Handle      : U64;
      Kind        : U64;
      Rights_Mask : U64;
      Name_Length : U64;
      Name        : Bootinfo_Name;
   end record;

   type Bootinfo_Entry_Array is array (0 .. 62) of Bootinfo_Entry;

   type Bootinfo_Page is record
      Magic   : U64;
      Count   : U64;
      Entries : Bootinfo_Entry_Array;
   end record;

   Bootinfo : Bootinfo_Page
     with Volatile, Address =>
       System'To_Address (System.Storage_Elements.Integer_Address
         (Bootinfo_VA));

   --  Bootinfo name lookup (init's namespace basis): resolve a
   --  kernel-assigned entry name (e.g. "uart/mmio", "Tests/Echo")
   --  to its cap handle; 0 when absent or bootinfo page invalid.
   function Boot_Cap (Name : String) return U64;

   --  Rights mask of the named entry as granted by the kernel;
   --  0 when absent. Children can be granted at most these rights.
   function Boot_Cap_Rights (Name : String) return U64;

   procedure Debug_Put (S : String);
   procedure Debug_Put_Line (S : String);
end Akernel_User.Syscalls;
