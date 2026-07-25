package body Kernel.Device_Tree is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U8  is Interfaces.Unsigned_8;
   subtype U32 is Interfaces.Unsigned_32;

   FDT_Magic      : constant U32 := 16#d00d_feed#;
   FDT_Begin_Node : constant U32 := 1;
   FDT_End_Node   : constant U32 := 2;
   FDT_Prop       : constant U32 := 3;
   FDT_Nop        : constant U32 := 4;
   FDT_End        : constant U32 := 9;

   function Mmio_Read8 (Address : U64) return U8
     with Import, Convention => C, External_Name => "mmio_read8";

   function Read_BE32 (Address : U64) return U32 is
      B0 : constant U32 := U32 (Mmio_Read8 (Address));
      B1 : constant U32 := U32 (Mmio_Read8 (Address + 1));
      B2 : constant U32 := U32 (Mmio_Read8 (Address + 2));
      B3 : constant U32 := U32 (Mmio_Read8 (Address + 3));
   begin
      return Interfaces.Shift_Left (B0, 24)
        or Interfaces.Shift_Left (B1, 16)
        or Interfaces.Shift_Left (B2, 8)
        or B3;
   end Read_BE32;

   function Align_4 (Value : U64) return U64 is
   begin
      return Value + ((4 - Value mod 4) mod 4);
   end Align_4;

   function C_String_Equals
     (Address  : U64;
      Expected : String) return Boolean
   is
      Index : U64 := 0;
   begin
      for C of Expected loop
         if Mmio_Read8 (Address + Index) /= Character'Pos (C) then
            return False;
         end if;
         Index := Index + 1;
      end loop;

      return Mmio_Read8 (Address + Index) = 0;
   end C_String_Equals;

   function Node_Name_Is_Memory (Address : U64) return Boolean is
      Prefix : constant String := "memory";
      Index  : U64 := 0;
      Next   : U8;
   begin
      for C of Prefix loop
         if Mmio_Read8 (Address + Index) /= Character'Pos (C) then
            return False;
         end if;
         Index := Index + 1;
      end loop;

      Next := Mmio_Read8 (Address + Index);
      return Next = 0 or else Next = Character'Pos ('@');
   end Node_Name_Is_Memory;

   function Read_Cells
     (Address : U64;
      Cells   : U32) return U64
   is
      Value : U64 := 0;
   begin
      for Index in U32 range 0 .. Cells - 1 loop
         Value := Interfaces.Shift_Left (Value, 32)
           or U64 (Read_BE32 (Address + U64 (Index) * 4));
      end loop;

      return Value;
   end Read_Cells;

   procedure Discover_Memory
     (DTB    : U64;
      Result : out Status;
      Base   : out U64;
      Size   : out U64)
   is
      Struct_Start  : U64;
      Struct_End    : U64;
      Strings       : U64;
      Cursor        : U64;
      Token         : U32;
      Len           : U32;
      Name_Offset   : U32;
      Data          : U64;
      Depth         : Natural := 0;
      Memory_Depth  : Natural := 0;
      Address_Cells : U32 := 2;
      Size_Cells    : U32 := 2;
   begin
      Base := 0;
      Size := 0;

      if Read_BE32 (DTB) /= FDT_Magic then
         Result := Bad_Magic;
         return;
      end if;

      Struct_Start := DTB + U64 (Read_BE32 (DTB + 8));
      Strings := DTB + U64 (Read_BE32 (DTB + 12));
      Struct_End := Struct_Start + U64 (Read_BE32 (DTB + 36));
      Cursor := Struct_Start;

      while Cursor < Struct_End loop
         Token := Read_BE32 (Cursor);
         Cursor := Cursor + 4;

         if Token = FDT_Begin_Node then
            if Node_Name_Is_Memory (Cursor) then
               Memory_Depth := Depth + 1;
            end if;

            Depth := Depth + 1;
            while Mmio_Read8 (Cursor) /= 0 loop
               Cursor := Cursor + 1;
            end loop;
            Cursor := Align_4 (Cursor + 1);

         elsif Token = FDT_End_Node then
            if Depth = Memory_Depth then
               Memory_Depth := 0;
            end if;

            if Depth = 0 then
               Result := Unsupported_Format;
               return;
            end if;
            Depth := Depth - 1;

         elsif Token = FDT_Prop then
            Len := Read_BE32 (Cursor);
            Name_Offset := Read_BE32 (Cursor + 4);
            Data := Cursor + 8;
            Cursor := Align_4 (Data + U64 (Len));

            if Depth = 1
              and then C_String_Equals
                (Strings + U64 (Name_Offset), "#address-cells")
            then
               Address_Cells := Read_BE32 (Data);
            elsif Depth = 1
              and then C_String_Equals
                (Strings + U64 (Name_Offset), "#size-cells")
            then
               Size_Cells := Read_BE32 (Data);
            elsif Memory_Depth /= 0
              and then C_String_Equals (Strings + U64 (Name_Offset), "reg")
            then
               if Address_Cells > 2 or else Size_Cells > 2 then
                  Result := Unsupported_Format;
                  return;
               end if;

               Base := Read_Cells (Data, Address_Cells);
               Size := Read_Cells (Data + U64 (Address_Cells) * 4, Size_Cells);
               Result := Ok;
               return;
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

      Result := Memory_Not_Found;
   end Discover_Memory;
end Kernel.Device_Tree;
