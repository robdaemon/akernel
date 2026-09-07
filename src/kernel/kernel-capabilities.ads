with Interfaces;
with System;

package Kernel.Capabilities is
   pragma SPARK_Mode (On);

   use type Interfaces.Unsigned_64;

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
      Notification_Object,
      --  Admin authority token (milestone 39): empty object,
      --  existence + Manage = introspection-dump authority
      --  (cap tables, register snapshots). Added LAST — kind
      --  position values ride the bootinfo wire format.
      Admin_Object);

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

   function To_Rights (Mask : U64) return Rights
     with
       --  Bit i of the mask maps to component i of Rights
       --  (Rights declaration order, bit 0 = Read .. bit 9 = Manage).
       Post =>
         (To_Rights'Result.Read     = ((Mask and 1) /= 0))    and then
         (To_Rights'Result.Write    = ((Mask and 2) /= 0))    and then
         (To_Rights'Result.Execute  = ((Mask and 4) /= 0))    and then
         (To_Rights'Result.Map      = ((Mask and 8) /= 0))    and then
         (To_Rights'Result.Send     = ((Mask and 16) /= 0))   and then
         (To_Rights'Result.Receive  = ((Mask and 32) /= 0))   and then
         (To_Rights'Result.Wait     = ((Mask and 64) /= 0))   and then
         (To_Rights'Result.Ack      = ((Mask and 128) /= 0))  and then
         (To_Rights'Result.Transfer = ((Mask and 256) /= 0))  and then
         (To_Rights'Result.Manage   = ((Mask and 512) /= 0));
   function To_Mask (R : Rights) return U64
     with
       --  Full encoding spec, mirroring To_Rights: component i maps to
       --  bit i, and no bits outside Valid_Rights_Mask are ever set.
       Post =>
         (To_Mask'Result and (not Valid_Rights_Mask)) = 0          and then
         (R.Read     = ((To_Mask'Result and 1) /= 0))              and then
         (R.Write    = ((To_Mask'Result and 2) /= 0))              and then
         (R.Execute  = ((To_Mask'Result and 4) /= 0))              and then
         (R.Map      = ((To_Mask'Result and 8) /= 0))              and then
         (R.Send     = ((To_Mask'Result and 16) /= 0))             and then
         (R.Receive  = ((To_Mask'Result and 32) /= 0))             and then
         (R.Wait     = ((To_Mask'Result and 64) /= 0))             and then
         (R.Ack      = ((To_Mask'Result and 128) /= 0))            and then
         (R.Transfer = ((To_Mask'Result and 256) /= 0))            and then
         (R.Manage   = ((To_Mask'Result and 512) /= 0));

   --  Grant-list validation lemma (kernel-processes Grant_List_Caps):
   --  the spawn validator rejects a rights mask iff it carries bits
   --  outside Valid_Rights_Mask — "Mask and not Valid_Rights_Mask = 0"
   --  (kernel-processes.adb:261). This lemma is that check expressed
   --  on the encoding: such a mask round-trips exactly. Call it (from
   --  Ghost/SPARK context) wherever a decoded mask is trusted.
   procedure Lemma_Mask_Round_Trip (Mask : U64) with
     Ghost,
     Pre  => (Mask and (not Valid_Rights_Mask)) = 0,
     Post => To_Mask (To_Rights (Mask)) = Mask;

   --  Grant-list subset check (Grant_List_Caps): after the
   --  unknown-bits rejection above, the validator requires the
   --  requested rights (decoded from the raw mask) to be a subset of
   --  the parent entry's rights. Raw-mask characterization of that
   --  check: every requested bit must already be set in the grantor's
   --  mask. Call both lemmas (from Ghost/SPARK context) wherever a
   --  grant list is validated against a parent's rights.
   procedure Lemma_Subset_Decode (Have : Rights; Mask : U64) with
     Ghost,
     Pre  => (Mask and (not Valid_Rights_Mask)) = 0,
     Post => Has_Rights (Have, To_Rights (Mask))
               = ((To_Mask (Have) and Mask) = Mask);

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

   function Has_Rights (Have : Rights; Need : Rights) return Boolean
     with
       --  Subset semantics, component by component: Have satisfies Need
       --  iff every right Need demands is present in Have.
       Post =>
         Has_Rights'Result =
           ((not Need.Read     or else Have.Read)     and then
            (not Need.Write    or else Have.Write)    and then
            (not Need.Execute  or else Have.Execute)  and then
            (not Need.Map      or else Have.Map)      and then
            (not Need.Send     or else Have.Send)     and then
            (not Need.Receive  or else Have.Receive)  and then
            (not Need.Wait     or else Have.Wait)     and then
            (not Need.Ack      or else Have.Ack)      and then
            (not Need.Transfer or else Have.Transfer) and then
            (not Need.Manage   or else Have.Manage));

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
