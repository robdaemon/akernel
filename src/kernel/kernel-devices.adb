with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Arch;
with Kernel.Interrupts;
with Kernel.Physical_Memory;

package body Kernel.Devices is
   use type Kernel.Objects.Refcount;
   use type Kernel.Physical_Memory.Status;
   use type System.Address;

   type Slot_Kind is (Slot_MMIO, Slot_IRQ);

   type Device_Slot is record
      Header    : Kernel.Objects.Object_Header;
      Kind      : Slot_Kind;
      Region    : aliased Kernel.Objects.MMIO_Region;
      Line      : aliased Kernel.Objects.IRQ_Line;
      Device_Id : U32;
      Next_Free : System.Address;
   end record;

   type Device_Slot_Access is access all Device_Slot;

   function To_Slot is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Device_Slot_Access);

   ------------------------------------------------------------------
   --  Slab pool (PMM-backed, grows per frame, RAM-limited; frames
   --  never returned — same policy as the endpoint slab)
   ------------------------------------------------------------------

   Free_Head : System.Address := System.Null_Address;

   procedure Free_Slot (Object : System.Address) is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      Slot.Next_Free := Free_Head;
      Free_Head := Object;
   end Free_Slot;

   procedure Grow_Pool (Result : out Status) is
      use System.Storage_Elements;

      Slot_Bytes : constant Storage_Count :=
        Storage_Count ((Device_Slot'Size + 127) / 128 * 16);
      Slots_Per_Frame : constant Natural :=
        Natural (Kernel.Physical_Memory.Page_Size) / Natural (Slot_Bytes);

      PMM_Result : Kernel.Physical_Memory.Status;
      Frame_PA   : U64;
      Base       : System.Address;
   begin
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame_PA);

      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := No_Memory;
         return;
      end if;

      Base := System'To_Address
        (Integer_Address (Arch.Phys_To_Virt (Frame_PA)));

      for Slot in 0 .. Slots_Per_Frame - 1 loop
         Free_Slot (Base + Storage_Offset (Slot) * Slot_Bytes);
      end loop;

      Result := Ok;
   end Grow_Pool;

   procedure Allocate_Slot (Result : out Status; Object : out System.Address) is
      Slot : Device_Slot_Access;
   begin
      if Free_Head = System.Null_Address then
         Grow_Pool (Result);
         if Result /= Ok then
            Object := System.Null_Address;
            return;
         end if;
      end if;

      Object := Free_Head;
      Slot := To_Slot (Object);
      Free_Head := Slot.Next_Free;
      Slot.Next_Free := System.Null_Address;
      Slot.Header.Count := 0;
      Result := Ok;
   end Allocate_Slot;

   procedure Create_MMIO
     (Base      : U64;
      Length    : U64;
      Device_Id : U32 := No_Device;
      Result    : out Status;
      Object    : out System.Address)
   is
      Slot : Device_Slot_Access;
   begin
      Allocate_Slot (Result, Object);
      if Result /= Ok then
         return;
      end if;

      Slot := To_Slot (Object);
      Slot.Kind := Slot_MMIO;
      Slot.Region := (Physical_Base => Base, Length => Length);
      Slot.Device_Id := Device_Id;
   end Create_MMIO;

   procedure Create_IRQ
     (Source : U64;
      Result : out Status;
      Object : out System.Address)
   is
      Slot : Device_Slot_Access;
   begin
      Allocate_Slot (Result, Object);
      if Result /= Ok then
         return;
      end if;

      Slot := To_Slot (Object);
      Slot.Kind := Slot_IRQ;
      Slot.Device_Id := No_Device;
      Slot.Line :=
        (Source     => Source,
         Pending    => False,
         In_Flight  => False,
         Waiter     => null,
         Ntfn       => System.Null_Address,
         Ntfn_Badge => 0,
         Next       => null);
   end Create_IRQ;

   function Region_Of
     (Object : System.Address) return access Kernel.Objects.MMIO_Region
   is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      if Object = System.Null_Address or else Slot.Kind /= Slot_MMIO then
         return null;
      end if;

      return Slot.Region'Unchecked_Access;
   end Region_Of;

   function Line_Of
     (Object : System.Address) return Kernel.Objects.IRQ_Line_Access
   is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      if Object = System.Null_Address or else Slot.Kind /= Slot_IRQ then
         return null;
      end if;

      return Slot.Line'Unchecked_Access;
   end Line_Of;

   function Device_Id_Of (Object : System.Address) return U32 is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      if Object = System.Null_Address or else Slot.Kind /= Slot_MMIO then
         return No_Device;
      end if;

      return Slot.Device_Id;
   end Device_Id_Of;

   procedure Retain (Object : System.Address) is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      Slot.Header.Count := Slot.Header.Count + 1;
   end Retain;

   function Release (Object : System.Address) return Boolean is
      Slot : constant Device_Slot_Access := To_Slot (Object);
   begin
      --  Count = 0 on a freshly allocated slot whose cap install
      --  failed (e.g. IRQ_Create on a duplicate source): free
      --  without decrementing or the subtraction raises and kills
      --  the kernel in the last-chance handler.
      if Slot.Header.Count = 0 then
         if Slot.Kind = Slot_IRQ then
            Kernel.Interrupts.Unregister (Slot.Line'Unchecked_Access);
         end if;

         Free_Slot (Object);
         return True;
      end if;

      Slot.Header.Count := Slot.Header.Count - 1;

      if Slot.Header.Count = 0 then
         if Slot.Kind = Slot_IRQ then
            Kernel.Interrupts.Unregister (Slot.Line'Unchecked_Access);
         end if;

         Free_Slot (Object);
         return True;
      end if;

      return False;
   end Release;
end Kernel.Devices;
