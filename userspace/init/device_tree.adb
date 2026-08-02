with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;

package body Device_Tree is
   use type U32;
   use type U64;
   use type U8;

   FDT_Magic      : constant U32 := 16#D00D_FEED#;
   FDT_Begin_Node : constant U32 := 1;
   FDT_End_Node   : constant U32 := 2;
   FDT_Prop       : constant U32 := 3;
   FDT_Nop        : constant U32 := 4;
   FDT_End        : constant U32 := 9;

   --  Constrained so access values stay thin pointers (an
   --  unconstrained array access would be a fat pointer and the
   --  address conversion would invent garbage bounds). 16 MiB is
   --  far past any FDT.
   type Byte_Array is array (U64 range 0 .. 16#FF_FFFF#) of U8
     with Volatile_Components;

   type Byte_Access is access all Byte_Array;

   function To_Bytes is new Ada.Unchecked_Conversion
     (System.Address, Byte_Access);

   Bytes : Byte_Access;

   function Read_BE32 (Offset : U64) return U32 is
   begin
      return Interfaces.Shift_Left (U32 (Bytes (Offset)), 24)
        or Interfaces.Shift_Left (U32 (Bytes (Offset + 1)), 16)
        or Interfaces.Shift_Left (U32 (Bytes (Offset + 2)), 8)
        or U32 (Bytes (Offset + 3));
   end Read_BE32;

   function Align_4 (Value : U64) return U64 is
   begin
      return Value + ((4 - Value mod 4) mod 4);
   end Align_4;

   --  #size-cells = 0 is legal FDT (qemu /cpus); guard the loop or
   --  Cells - 1 wraps to U32'Last and the walk runs off the mapping.
   function Read_Cells (Offset : U64; Cells : U32) return U64 is
      Value : U64 := 0;
   begin
      if Cells = 0 then
         return 0;
      end if;

      for I in U32 range 0 .. Cells - 1 loop
         Value := Interfaces.Shift_Left (Value, 32)
           or U64 (Read_BE32 (Offset + U64 (I) * 4));
      end loop;
      return Value;
   end Read_Cells;

   function Prop_Name_Equals (Offset : U64; Value : String) return Boolean is
      Cursor : U64 := Offset;
   begin
      for I in Value'Range loop
         if Bytes (Cursor) /= Character'Pos (Value (I)) then
            return False;
         end if;
         Cursor := Cursor + 1;
      end loop;
      return Bytes (Cursor) = 0;
   end Prop_Name_Equals;

   procedure Walk
     (Base    : U64;
      On_Node : Node_Handler;
      Result  : out Status)
   is
      Struct_Start : U64;
      Struct_End   : U64;
      Strings      : U64;
      Cursor       : U64;
      Token        : U32;
      Len          : U32;
      Name_Offset  : U32;
      Data         : U64;
      Depth        : Natural := 0;

      Cell_A : array (0 .. Max_Depth) of U32 := (others => 2);
      Cell_S : array (0 .. Max_Depth) of U32 := (others => 2);

      Node : Node_Info;

      procedure Reset_Node is
      begin
         Node := (Compatibles => (others => <>),
                  Compatible_Count => 0,
                  Base => 0, Size => 0, IRQ => 0);
      end Reset_Node;

   begin
      Result := Ok;
      Bytes := To_Bytes
        (System.Storage_Elements.To_Address
           (System.Storage_Elements.Integer_Address (Base)));

      if Read_BE32 (0) /= FDT_Magic then
         Result := Bad_Magic;
         return;
      end if;

      Struct_Start := U64 (Read_BE32 (8));
      Strings := U64 (Read_BE32 (12));
      Struct_End := Struct_Start + U64 (Read_BE32 (36));
      Cursor := Struct_Start;

      Reset_Node;

      while Cursor < Struct_End loop
         Token := Read_BE32 (Cursor);
         Cursor := Cursor + 4;

         if Token = FDT_Begin_Node then
            if Depth = Max_Depth then
               Result := Unsupported_Format;
               return;
            end if;

            Depth := Depth + 1;
            --  Children inherit the parent's cells; the node's own
            --  #address-cells/#size-cells override for its children
            --  only (its reg is read with Cell_*(Depth - 1)).
            Cell_A (Depth) := Cell_A (Depth - 1);
            Cell_S (Depth) := Cell_S (Depth - 1);
            Reset_Node;

            while Bytes (Cursor) /= 0 loop
               Cursor := Cursor + 1;
            end loop;
            Cursor := Align_4 (Cursor + 1);

         elsif Token = FDT_End_Node then
            if Depth = 0 then
               Result := Unsupported_Format;
               return;
            end if;

            if Node.Compatible_Count > 0 then
               On_Node (Node);
            end if;

            Depth := Depth - 1;

         elsif Token = FDT_Prop then
            Len := Read_BE32 (Cursor);
            Name_Offset := Read_BE32 (Cursor + 4);
            Data := Cursor + 8;
            Cursor := Align_4 (Data + U64 (Len));

            if Depth = 0 then
               Result := Unsupported_Format;
               return;
            end if;

            if Prop_Name_Equals
              (Strings + U64 (Name_Offset), "#address-cells")
            then
               Cell_A (Depth) := Read_BE32 (Data);
            elsif Prop_Name_Equals
              (Strings + U64 (Name_Offset), "#size-cells")
            then
               Cell_S (Depth) := Read_BE32 (Data);
            elsif Prop_Name_Equals
              (Strings + U64 (Name_Offset), "compatible")
            then
               --  NUL-separated string list: keep the first
               --  Max_Compatible entries.
               declare
                  Entry_Start : U64 := Data;
                  Pos         : U64 := Data;
               begin
                  while Pos < Data + U64 (Len) loop
                     if Bytes (Pos) = 0 then
                        if Node.Compatible_Count < Max_Compatible
                          and then Pos > Entry_Start
                          and then Pos - Entry_Start <= Max_Name
                        then
                           Node.Compatible_Count :=
                             Node.Compatible_Count + 1;
                           declare
                              Slot : Compatible_String
                                renames Node.Compatibles
                                  (Node.Compatible_Count);
                              Entry_Len : constant Natural :=
                                Natural (Pos - Entry_Start);
                           begin
                              Slot.Length := Entry_Len;
                              for I in 0 .. Entry_Len - 1 loop
                                 Slot.Text (I + 1) :=
                                   Character'Val
                                     (Natural (Bytes (Entry_Start + U64 (I))));
                              end loop;
                           end;
                        end if;
                        Entry_Start := Pos + 1;
                     end if;
                     Pos := Pos + 1;
                  end loop;
               end;
            elsif Prop_Name_Equals
              (Strings + U64 (Name_Offset), "reg")
              and then Node.Base = 0
              and then Node.Size = 0
            then
               if Cell_A (Depth - 1) > 2 or else Cell_S (Depth - 1) > 2 then
                  Result := Unsupported_Format;
                  return;
               end if;

               Node.Base := Read_Cells (Data, Cell_A (Depth - 1));
               Node.Size := Read_Cells
                 (Data + U64 (Cell_A (Depth - 1)) * 4,
                  Cell_S (Depth - 1));
            elsif Prop_Name_Equals
              (Strings + U64 (Name_Offset), "interrupts")
              and then Node.IRQ = 0
              and then Len >= 4
            then
               Node.IRQ := U64 (Read_BE32 (Data));
            end if;

         elsif Token = FDT_Nop then
            null;
         elsif Token = FDT_End then
            exit;
         else
            Result := Unsupported_Format;
            return;
         end if;
      end loop;
   end Walk;
end Device_Tree;
