with Ada.Unchecked_Conversion;
with System.Machine_Code;
with System.Storage_Elements;

package body Virtio.Queues is
   use type System.Address;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   ------------------------------------------------------------------
   --  Ring area overlays (little-endian, matches RISC-V native)
   ------------------------------------------------------------------

   type Descriptor is record
      Addr  : U64;
      Len   : U32;
      Flags : U16;
      Next  : U16;
   end record with Pack;

   type Descriptor_Array is array (U16 range 0 .. Max_Num - 1)
     of Descriptor with Volatile_Components;

   type Descriptor_Access is access all Descriptor_Array;

   type U16_Array is array (U16 range 0 .. Max_Num - 1) of U16
     with Volatile_Components;

   type Avail_Ring is record
      Flags : U16;
      Idx   : U16;
      Ring  : U16_Array;
   end record with Pack, Volatile;

   type Avail_Access is access all Avail_Ring;

   type Used_Elem is record
      Id  : U32;
      Len : U32;
   end record with Pack;

   type Used_Elem_Array is array (U16 range 0 .. Max_Num - 1)
     of Used_Elem with Volatile_Components;

   type Used_Ring is record
      Flags : U16;
      Idx   : U16;
      Ring  : Used_Elem_Array;
   end record with Pack, Volatile;

   type Used_Access is access all Used_Ring;

   function To_Desc is new Ada.Unchecked_Conversion
     (System.Address, Descriptor_Access);
   function To_Avail is new Ada.Unchecked_Conversion
     (System.Address, Avail_Access);
   function To_Used is new Ada.Unchecked_Conversion
     (System.Address, Used_Access);

   procedure Fence is
   begin
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
   end Fence;

   procedure Initialize
     (Q     : in out Queue;
      Desc  : System.Address;
      Avail : System.Address;
      Used  : System.Address;
      Num   : U16)
   is
      D : constant Descriptor_Access := To_Desc (Desc);
   begin
      Q.Desc := Desc;
      Q.Avail := Avail;
      Q.Used := Used;
      Q.Num := Num;
      Q.Avail_Idx := 0;
      Q.Used_Idx := 0;

      --  Zero the areas and chain every descriptor onto the free
      --  list: 0 -> 1 -> ... -> Num-1 -> No_Desc.
      for I in U16 range 0 .. Num - 1 loop
         D (I).Addr := 0;
         D (I).Len := 0;
         D (I).Flags := 0;
         D (I).Next := (if I = Num - 1 then No_Desc else I + 1);
      end loop;

      declare
         A : constant Avail_Access := To_Avail (Avail);
         U : constant Used_Access := To_Used (Used);
      begin
         A.Flags := 0;
         A.Idx := 0;
         for I in U16 range 0 .. Num - 1 loop
            A.Ring (I) := 0;
            U.Ring (I) := (Id => 0, Len => 0);
         end loop;
         U.Flags := 0;
         U.Idx := 0;
      end;

      Q.Free_Head := (if Num = 0 then No_Desc else 0);
      Q.Free_Count := Num;
   end Initialize;

   function Alloc (Q : in out Queue) return U16 is
      D : constant Descriptor_Access := To_Desc (Q.Desc);
      Head : constant U16 := Q.Free_Head;
   begin
      if Head = No_Desc then
         return No_Desc;
      end if;

      Q.Free_Head := D (Head).Next;
      Q.Free_Count := Q.Free_Count - 1;
      D (Head).Next := No_Desc;
      D (Head).Flags := 0;
      return Head;
   end Alloc;

   procedure Free (Q : in out Queue; Head : U16) is
      D : constant Descriptor_Access := To_Desc (Q.Desc);
      Cursor : U16 := Head;
      Next   : U16;
   begin
      --  Walk the chain to its tail, then splice onto the free list.
      while Cursor /= No_Desc loop
         Next := (if (D (Cursor).Flags and Desc_F_Next) /= 0
                  then D (Cursor).Next
                  else No_Desc);
         D (Cursor).Flags := 0;
         Q.Free_Count := Q.Free_Count + 1;

         if Next = No_Desc then
            D (Cursor).Next := Q.Free_Head;
            Q.Free_Head := Head;
         end if;

         Cursor := Next;
      end loop;
   end Free;

   procedure Set_Buffer
     (Q             : in out Queue;
      Index         : U16;
      PA            : U64;
      Length        : U32;
      Device_Writes : Boolean)
   is
      D : constant Descriptor_Access := To_Desc (Q.Desc);
   begin
      D (Index).Addr := PA;
      D (Index).Len := Length;
      D (Index).Flags := (if Device_Writes then Desc_F_Write else 0);
   end Set_Buffer;

   procedure Chain_Next (Q : in out Queue; Index : U16; Next : U16) is
      D : constant Descriptor_Access := To_Desc (Q.Desc);
   begin
      D (Index).Next := Next;
      D (Index).Flags := D (Index).Flags or Desc_F_Next;
   end Chain_Next;

   procedure Submit (Q : in out Queue; Head : U16) is
      A : constant Avail_Access := To_Avail (Q.Avail);
      Slot : constant U16 := Q.Avail_Idx mod Q.Num;
   begin
      A.Ring (Slot) := Head;
      Fence;
      Q.Avail_Idx := Q.Avail_Idx + 1;
      A.Idx := Q.Avail_Idx;
      Fence;
   end Submit;

   function Has_Completed (Q : Queue) return Boolean is
      U : constant Used_Access := To_Used (Q.Used);
   begin
      Fence;
      return U.Idx /= Q.Used_Idx;
   end Has_Completed;

   procedure Pop
     (Q      : in out Queue;
      Head   : out U16;
      Length : out U32)
   is
      U : constant Used_Access := To_Used (Q.Used);
      Slot : constant U16 := Q.Used_Idx mod Q.Num;
      Elem : constant Used_Elem := U.Ring (Slot);
   begin
      Q.Used_Idx := Q.Used_Idx + 1;
      Head := U16 (Elem.Id);
      Length := Elem.Len;
   end Pop;
end Virtio.Queues;
