with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Arch;
with Kernel.Physical_Memory;

package body Kernel.Memory is
   use type Interfaces.Unsigned_64;
   use type Kernel.Objects.Refcount;
   use type Kernel.Physical_Memory.Status;
   use type System.Address;

   type Memory_Object_Access is access all Memory_Object;

   function To_Memory_Object is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Memory_Object_Access);

   procedure Zero_Frame (Physical : U64) is
      use System.Storage_Elements;

      type Word_Array is array (0 .. 511) of U64;
      type Word_Array_Access is access all Word_Array;

      function To_Words is new Ada.Unchecked_Conversion
        (Source => System.Address,
         Target => Word_Array_Access);

      Words : constant Word_Array_Access := To_Words
        (System'To_Address
           (Integer_Address (Arch.Phys_To_Virt (Physical))));
   begin
      Words.all := (others => 0);
   end Zero_Frame;

   ------------------------------------------------------------------
   --  Slab pool (PMM-backed, grows per frame, RAM-limited; frames
   --  never returned — same policy as the endpoint slab)
   ------------------------------------------------------------------

   Free_Head : System.Address := System.Null_Address;

   procedure Free_Slot (Object : System.Address) is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      Slot.Next_Free := Free_Head;
      Free_Head := Object;
   end Free_Slot;

   procedure Grow_Pool (Result : out Status) is
      use System.Storage_Elements;

      Slot_Bytes : constant Storage_Count :=
        Storage_Count ((Memory_Object'Size + 127) / 128 * 16);
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

   procedure Free_Frames (Object : Memory_Object_Access) is
      PMM_Result : Kernel.Physical_Memory.Status;
   begin
      for Index in 0 .. Object.Pages - 1 loop
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => Object.Frames (Natural (Index)),
            Result => PMM_Result);
      end loop;
   end Free_Frames;

   procedure Create
     (Pages  : U64;
      Result : out Status;
      Object : out System.Address)
   is
      Slot       : Memory_Object_Access;
      PMM_Result : Kernel.Physical_Memory.Status;
      Frame      : U64;
   begin
      Object := System.Null_Address;

      if Pages = 0 or else Pages > U64 (Max_Pages) then
         Result := No_Memory;
         return;
      end if;

      if Free_Head = System.Null_Address then
         Grow_Pool (Result);
         if Result /= Ok then
            return;
         end if;
      end if;

      Slot := To_Memory_Object (Free_Head);
      Free_Head := Slot.Next_Free;
      Slot.Next_Free := System.Null_Address;
      Slot.Header.Count := 0;
      Slot.Pages := Pages;
      Slot.Frames := (others => 0);

      for Index in 0 .. Pages - 1 loop
         Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame);
         if PMM_Result /= Kernel.Physical_Memory.Ok then
            --  Roll back: frames allocated so far + slab slot.
            Slot.Pages := Index;
            Free_Frames (Slot);
            Free_Slot (Slot.all'Address);
            Result := No_Memory;
            return;
         end if;

         Zero_Frame (Frame);
         Slot.Frames (Natural (Index)) := Frame;
      end loop;

      Object := Slot.all'Address;
      Result := Ok;
   end Create;

   procedure Discard (Object : System.Address) is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      if Slot = null then
         return;
      end if;

      Free_Frames (Slot);
      Free_Slot (Object);
   end Discard;

   procedure Retain (Object : System.Address) is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      if Slot = null then
         return;
      end if;

      Slot.Header.Count := Slot.Header.Count + 1;
   end Retain;

   function Release (Object : System.Address) return Boolean is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      if Slot = null or else Slot.Header.Count = 0 then
         return False;
      end if;

      Slot.Header.Count := Slot.Header.Count - 1;
      if Slot.Header.Count /= 0 then
         return False;
      end if;

      Free_Frames (Slot);
      Free_Slot (Object);
      return True;
   end Release;

   function Page_Count (Object : System.Address) return U64 is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      if Slot = null then
         return 0;
      end if;

      return Slot.Pages;
   end Page_Count;

   function Frame_At
     (Object : System.Address;
      Index  : U64) return U64
   is
      Slot : constant Memory_Object_Access := To_Memory_Object (Object);
   begin
      if Slot = null or else Index >= Slot.Pages then
         return 0;
      end if;

      return Slot.Frames (Natural (Index));
   end Frame_At;

end Kernel.Memory;
