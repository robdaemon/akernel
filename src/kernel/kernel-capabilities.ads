with Interfaces;
with System;

package Kernel.Capabilities is
   subtype U64 is Interfaces.Unsigned_64;

   --  16K handles per process. The table is PAGED (milestone 38):
   --  one 4 KiB PMM frame per 128 caps, allocated on demand and
   --  accessed through the physmap, so a small process costs one
   --  frame and the 128-slot PCB array costs root arrays only
   --  (~1.5 KB each) instead of 10 KB of static entries each.
   Max_Caps : constant := 16384;

   type Handle is range 0 .. Max_Caps - 1;
   Invalid_Handle : constant Handle := 0;

   type Object_Kind is
     (Null_Object,
      Frame_Object,
      Address_Space_Object,
      Process_Object,
      Thread_Object,
      Endpoint_Object,
      Reply_Object,
      IRQ_Object,
      MMIO_Object,
      DMA_Object,
      Kernel_Object,
      Boot_File_Object,
      Memory_Object,
      Notification_Object);

   type Rights is record
      Read     : Boolean;
      Write    : Boolean;
      Execute  : Boolean;
      Map      : Boolean;
      Send     : Boolean;
      Receive  : Boolean;
      Wait     : Boolean;
      Ack      : Boolean;
      Transfer : Boolean;
      Manage   : Boolean;
   end record;

   No_Rights : constant Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   All_Rights : constant Rights :=
     (Read     => True,
      Write    => True,
      Execute  => True,
      Map      => True,
      Send     => True,
      Receive  => True,
      Wait     => True,
      Ack      => True,
      Transfer => True,
      Manage   => True);

   --  Userspace rights-mask encoding (spawn grant lists, docs/IPC.md):
   --  bits 0..9 in Rights declaration order (Read = bit 0 ..
   --  Manage = bit 9). Masks with bits outside Valid_Rights_Mask are
   --  rejected by the kernel.
   Valid_Rights_Mask : constant U64 := 16#3FF#;

   function To_Rights (Mask : U64) return Rights;
   function To_Mask (R : Rights) return U64;

   --  Layout is FORCED to exactly 32 bytes by the rep clause:
   --  128 entries then fill a 4 KiB cap page precisely, and the
   --  compiler rejects any drift (a plain pragma Assert is no
   --  guard here — assertions are disabled in the kernel build,
   --  which let a 40-byte entry spill slot 127 past the frame end
   --  and into the next page's frame, wiped by its Zero_Page;
   --  milestone-38 bringup burn). Field order keeps Object/Badge
   --  8-aligned; a zeroed frame remains a page of Null_Cap.
   type Cap_Entry is record
      Object : System.Address;
      Badge  : U64;
      Rights : Kernel.Capabilities.Rights;
      Valid  : Boolean;
      Kind   : Object_Kind;
   end record;

   for Cap_Entry use record
      Object at  0 range 0 .. 63;
      Badge  at  8 range 0 .. 63;
      Rights at 16 range 0 .. 79;
      Valid  at 26 range 0 ..  7;
      Kind   at 27 range 0 ..  7;
   end record;
   for Cap_Entry'Size use 256;

   Null_Cap : constant Cap_Entry :=
     (Valid  => False,
      Kind   => Null_Object,
      Object => System.Null_Address,
      Rights => No_Rights,
      Badge  => 0);

   type Cap_Table is private;

   type Status is
     (Ok,
      Invalid_Cap,
      Invalid_Object,
      Rights_Denied,
      Table_Full,
      Slot_Occupied);

   procedure Initialize (Table : out Cap_Table);

   function Has_Rights (Have : Rights; Need : Rights) return Boolean;

   procedure Insert
     (Table  : in out Cap_Table;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status;
      Cap    : out Handle);

   procedure Insert_At
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status);

   procedure Lookup
     (Table     : Cap_Table;
      Cap       : Handle;
      Result    : out Status;
      Out_Entry : out Cap_Entry);

   procedure Duplicate
     (Table     : in out Cap_Table;
      Source    : Handle;
      New_Rights : Kernel.Capabilities.Rights;
      New_Badge  : U64;
      Result    : out Status;
      New_Cap   : out Handle);

   procedure Close
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Result : out Status);

   procedure Reset (Table : out Cap_Table);

   function Used_Count (Table : Cap_Table) return Natural;

private
   Caps_Per_Page : constant := 128;
   Page_Count    : constant := Max_Caps / Caps_Per_Page;  --  128
   --  Page fit is compile-time guaranteed by the Cap_Entry size
   --  clause above: 128 x 32 bytes = 4096 exactly.

   type Page_Index is range 0 .. Page_Count - 1;
   type Root_Array  is array (Page_Index) of U64;     --  frame PA or 0
   type Count_Array is array (Page_Index) of Natural; --  live entries

   type Cap_Table is record
      Root  : Root_Array := (others => 0);
      Count : Count_Array := (others => 0);
      Total : Natural := 0;
   end record;
end Kernel.Capabilities;
