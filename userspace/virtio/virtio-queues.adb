with Ada.Unchecked_Conversion;
with System.Machine_Code;
with System.Storage_Elements;

package body Virtio.Queues is
   use type System.Address;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   ------------------------------------------------------------------
   --  Ring area overlays as flat volatile arrays with explicit
   --  element offsets. Record overlays with Pack+Volatile proved
   --  unreliable (the compiler is free to ignore Pack on volatile
   --  types, shifting field offsets).
   --
   --  Descriptor table (U32 view): descriptor i at words i*4 ..
   --    +0 addr low, +1 addr high, +2 len, +3 flags | next << 16.
   --  Available ring (U16 view): +0 flags, +1 idx, +2+i ring.
   --  Used ring (U32 view): +0 flags | idx << 16,
   --    elem i at +1+i*2 (id) and +2+i*2 (len).
   ------------------------------------------------------------------

   type U32_Array is array (U16 range 0 .. 1023) of U32
     with Volatile_Components;
   type U16_Array is array (U16 range 0 .. 2047) of U16
     with Volatile_Components;

   type U32_Access is access all U32_Array;
   type U16_Access is access all U16_Array;

   function To_U32s is new Ada.Unchecked_Conversion
     (System.Address, U32_Access);
   function To_U16s is new Ada.Unchecked_Conversion
     (System.Address, U16_Access);

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
      D : constant U32_Access := To_U32s (Desc);
      A : constant U16_Access := To_U16s (Avail);
      U : constant U32_Access := To_U32s (Used);
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
         D (I * 4) := 0;
         D (I * 4 + 1) := 0;
         D (I * 4 + 2) := 0;
         D (I * 4 + 3) :=
           U32 (if I = Num - 1 then No_Desc else I + 1)
             * 16#1_0000#;  --  next in the high half, flags 0
      end loop;

      for I in U16 range 0 .. 2 * Num + 1 loop
         U (I) := 0;
      end loop;
      for I in U16 range 0 .. Num + 1 loop
         A (I) := 0;
      end loop;

      Q.Free_Head := (if Num = 0 then No_Desc else 0);
      Q.Free_Count := Num;
   end Initialize;

   function Alloc (Q : in out Queue) return U16 is
      D : constant U32_Access := To_U32s (Q.Desc);
      Head : constant U16 := Q.Free_Head;
   begin
      if Head = No_Desc then
         return No_Desc;
      end if;

      Q.Free_Head := U16 (D (Head * 4 + 3) / 16#1_0000#);
      Q.Free_Count := Q.Free_Count - 1;
      D (Head * 4 + 3) := U32 (No_Desc) * 16#1_0000#;
      return Head;
   end Alloc;

   procedure Free (Q : in out Queue; Head : U16) is
      D : constant U32_Access := To_U32s (Q.Desc);
      Cursor : U16 := Head;
      Next   : U16;
      Word   : U32;
   begin
      --  Walk the chain to its tail, then splice onto the free list.
      while Cursor /= No_Desc loop
         Word := D (Cursor * 4 + 3);
         Next := (if (Word and U32 (Desc_F_Next)) /= 0
                  then U16 (Word / 16#1_0000#)
                  else No_Desc);
         D (Cursor * 4 + 3) := 0;
         Q.Free_Count := Q.Free_Count + 1;

         if Next = No_Desc then
            D (Cursor * 4 + 3) := U32 (Q.Free_Head) * 16#1_0000#;
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
      D : constant U32_Access := To_U32s (Q.Desc);
      Flags : constant U32 :=
        (if Device_Writes then U32 (Desc_F_Write) else 0);
   begin
      D (Index * 4)     := U32 (PA and 16#FFFF_FFFF#);
      D (Index * 4 + 1) := U32 (Interfaces.Shift_Right (PA, 32));
      D (Index * 4 + 2) := Length;
      --  NEXT clear: the device ignores the (zeroed) next half.
      D (Index * 4 + 3) := Flags;
   end Set_Buffer;

   procedure Chain_Next (Q : in out Queue; Index : U16; Next : U16) is
      D : constant U32_Access := To_U32s (Q.Desc);
   begin
      D (Index * 4 + 3) :=
        (D (Index * 4 + 3) and 16#FFFF#)
          or U32 (Desc_F_Next)
          or U32 (Next) * 16#1_0000#;
   end Chain_Next;

   procedure Submit (Q : in out Queue; Head : U16) is
      A : constant U16_Access := To_U16s (Q.Avail);
      Slot : constant U16 := Q.Avail_Idx mod Q.Num;
   begin
      A (2 + Slot) := Head;
      Fence;
      Q.Avail_Idx := Q.Avail_Idx + 1;
      A (1) := Q.Avail_Idx;
      Fence;
   end Submit;

   function Has_Completed (Q : Queue) return Boolean is
      U : constant U32_Access := To_U32s (Q.Used);
   begin
      Fence;
      return U16 (U (0) / 16#1_0000#) /= Q.Used_Idx;
   end Has_Completed;

   procedure Pop
     (Q      : in out Queue;
      Head   : out U16;
      Length : out U32)
   is
      U : constant U32_Access := To_U32s (Q.Used);
      Slot : constant U16 := Q.Used_Idx mod Q.Num;
   begin
      Q.Used_Idx := Q.Used_Idx + 1;
      Head := U16 (U (1 + Slot * 2));
      Length := U (2 + Slot * 2);
   end Pop;
end Virtio.Queues;
