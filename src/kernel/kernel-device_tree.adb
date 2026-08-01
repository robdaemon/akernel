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
      --  Cells = 0 is legal FDT (#size-cells = 0 means no size); a
      --  modular U32 range of 0 .. Cells - 1 would wrap around.
      if Cells = 0 then
         return 0;
      end if;

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

   --  Matches one entry of a compatible string list: a run of
   --  NUL-separated strings of total Len bytes at Address.
   function Compatible_List_Contains
     (Address  : U64;
      Len      : U32;
      Expected : String) return Boolean
   is
      Entry_Start : U64 := Address;
      Entry_Len   : U64 := 0;
      Cursor      : U64 := Address;
      Byte        : U8;
   begin
      while Cursor < Address + U64 (Len) loop
         Byte := Mmio_Read8 (Cursor);
         if Byte = 0 then
            if Entry_Len = Expected'Length
              and then Entry_Len > 0
            then
               declare
                  Match : Boolean := True;
               begin
                  for I in Expected'Range loop
                     if Mmio_Read8
                         (Entry_Start + U64 (I - Expected'First))
                       /= Character'Pos (Expected (I))
                     then
                        Match := False;
                        exit;
                     end if;
                  end loop;
                  if Match then
                     return True;
                  end if;
               end;
            end if;
            Entry_Start := Cursor + 1;
            Entry_Len := 0;
         else
            Entry_Len := Entry_Len + 1;
         end if;
         Cursor := Cursor + 1;
      end loop;
      return False;
   end Compatible_List_Contains;

   procedure Find_Device
     (DTB        : U64;
      Compatible : String;
      Base       : out U64;
      Size       : out U64;
      IRQ_Source : out U64;
      Result     : out Status)
   is
      Max_Depth : constant := 16;
      type U32_Stack is array (0 .. Max_Depth) of U32;
      type U64_Stack is array (0 .. Max_Depth) of U64;
      type Bool_Stack is array (0 .. Max_Depth) of Boolean;

      Struct_Start  : U64;
      Struct_End    : U64;
      Strings       : U64;
      Cursor        : U64;
      Token         : U32;
      Len           : U32;
      Name_Offset   : U32;
      Data          : U64;
      Depth         : Natural := 0;
      --  Property order inside a node is arbitrary (qemu emits reg
      --  before compatible), so each node's reg/interrupts/compatible
      --  are captured independently and the match decision happens
      --  when the node closes.
      Node_Match    : Bool_Stack := (others => False);
      Node_Has_Reg  : Bool_Stack := (others => False);
      Node_Base     : U64_Stack  := (others => 0);
      Node_Size     : U64_Stack  := (others => 0);
      Node_IRQ      : U64_Stack  := (others => 0);
      --  Address/size cells per depth, inherited from the parent
      --  node (FDT default is 2/1; both are 2 on qemu virt).
      Addr_Cells    : U32_Stack := (others => 2);
      Size_Cells    : U32_Stack := (others => 1);
   begin
      Base := 0;
      Size := 0;
      IRQ_Source := 0;

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
            if Depth < Max_Depth then
               Addr_Cells (Depth + 1) := Addr_Cells (Depth);
               Size_Cells (Depth + 1) := Size_Cells (Depth);
            else
               Result := Unsupported_Format;
               return;
            end if;

            Depth := Depth + 1;
            Node_Match (Depth) := False;
            Node_Has_Reg (Depth) := False;
            Node_IRQ (Depth) := 0;
            while Mmio_Read8 (Cursor) /= 0 loop
               Cursor := Cursor + 1;
            end loop;
            Cursor := Align_4 (Cursor + 1);

         elsif Token = FDT_End_Node then
            if Depth = 0 then
               Result := Unsupported_Format;
               return;
            end if;

            if Node_Match (Depth) then
               --  First matching node in document order wins; a
               --  matched node without reg is malformed for our use.
               if Node_Has_Reg (Depth) then
                  Base := Node_Base (Depth);
                  Size := Node_Size (Depth);
                  IRQ_Source := Node_IRQ (Depth);
                  Result := Ok;
               else
                  Result := Device_Not_Found;
               end if;
               return;
            end if;
            Depth := Depth - 1;

         elsif Token = FDT_Prop then
            Len := Read_BE32 (Cursor);
            Name_Offset := Read_BE32 (Cursor + 4);
            Data := Cursor + 8;
            Cursor := Align_4 (Data + U64 (Len));

            if C_String_Equals
              (Strings + U64 (Name_Offset), "#address-cells")
            then
               Addr_Cells (Depth) := Read_BE32 (Data);
            elsif C_String_Equals
              (Strings + U64 (Name_Offset), "#size-cells")
            then
               Size_Cells (Depth) := Read_BE32 (Data);
            elsif C_String_Equals
                    (Strings + U64 (Name_Offset), "compatible")
              and then Compatible_List_Contains (Data, Len, Compatible)
            then
               Node_Match (Depth) := True;
            elsif C_String_Equals (Strings + U64 (Name_Offset), "reg")
            then
               --  reg cells are interpreted with the parent node's
               --  address/size cells.
               if Addr_Cells (Depth - 1) > 2
                 or else Size_Cells (Depth - 1) > 2
               then
                  Result := Unsupported_Format;
                  return;
               end if;

               Node_Base (Depth) :=
                 Read_Cells (Data, Addr_Cells (Depth - 1));
               Node_Size (Depth) := Read_Cells
                 (Data + U64 (Addr_Cells (Depth - 1)) * 4,
                  Size_Cells (Depth - 1));
               Node_Has_Reg (Depth) := True;
            elsif C_String_Equals
              (Strings + U64 (Name_Offset), "interrupts")
            then
               Node_IRQ (Depth) := U64 (Read_BE32 (Data));
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

      Result := Device_Not_Found;
   end Find_Device;

   procedure Enumerate_Cpus
     (DTB    : U64;
      Ids    : out Cpu_Id_List;
      Count  : out Natural;
      Result : out Status)
   is
      Max_Depth : constant := 16;
      type U32_Stack is array (0 .. Max_Depth) of U32;
      type U64_Stack is array (0 .. Max_Depth) of U64;
      type Bool_Stack is array (0 .. Max_Depth) of Boolean;

      Struct_Start : U64;
      Struct_End   : U64;
      Strings      : U64;
      Cursor       : U64;
      Token        : U32;
      Len          : U32;
      Name_Offset  : U32;
      Data         : U64;
      Depth        : Natural := 0;
      --  Depth of the /cpus node; 0 means "not yet inside".  CPU
      --  nodes are its direct children (Depth = Cpus_Depth + 1).
      Cpus_Depth   : Natural := 0;
      Is_Cpu       : Bool_Stack := (others => False);
      Has_Reg      : Bool_Stack := (others => False);
      Cpu_Reg      : U64_Stack := (others => 0);
      Addr_Cells   : U32_Stack := (others => 2);
   begin
      Ids := (others => 0);
      Count := 0;

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
            if Depth >= Max_Depth then
               Result := Unsupported_Format;
               return;
            end if;

            Addr_Cells (Depth + 1) := Addr_Cells (Depth);
            Depth := Depth + 1;
            Is_Cpu (Depth) := False;
            Has_Reg (Depth) := False;

            if Cpus_Depth = 0
              and then C_String_Equals (Cursor, "cpus")
            then
               Cpus_Depth := Depth;
            end if;

            while Mmio_Read8 (Cursor) /= 0 loop
               Cursor := Cursor + 1;
            end loop;
            Cursor := Align_4 (Cursor + 1);

         elsif Token = FDT_End_Node then
            if Depth = 0 then
               Result := Unsupported_Format;
               return;
            end if;

            if Cpus_Depth /= 0 and then Depth = Cpus_Depth + 1 then
               if Is_Cpu (Depth)
                 and then Has_Reg (Depth)
                 and then Count < Max_Cpus
               then
                  Ids (Count) := Cpu_Reg (Depth);
                  Count := Count + 1;
               end if;
            elsif Cpus_Depth /= 0 and then Depth = Cpus_Depth then
               --  Leaving /cpus: all CPU nodes were direct children.
               Result := Ok;
               return;
            end if;
            Depth := Depth - 1;

         elsif Token = FDT_Prop then
            Len := Read_BE32 (Cursor);
            Name_Offset := Read_BE32 (Cursor + 4);
            Data := Cursor + 8;
            Cursor := Align_4 (Data + U64 (Len));

            if C_String_Equals
              (Strings + U64 (Name_Offset), "#address-cells")
            then
               Addr_Cells (Depth) := Read_BE32 (Data);
            elsif Cpus_Depth /= 0 and then Depth = Cpus_Depth + 1 then
               if C_String_Equals
                    (Strings + U64 (Name_Offset), "device_type")
                 and then C_String_Equals (Data, "cpu")
               then
                  Is_Cpu (Depth) := True;
               elsif C_String_Equals
                    (Strings + U64 (Name_Offset), "reg")
                 and then Addr_Cells (Depth - 1) in 1 .. 2
               then
                  Cpu_Reg (Depth) :=
                    Read_Cells (Data, Addr_Cells (Depth - 1));
                  Has_Reg (Depth) := True;
               end if;
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

      --  FDT_End without leaving /cpus (or no /cpus at all): whatever
      --  was collected stands; an empty list is Device_Not_Found.
      if Count > 0 then
         Result := Ok;
      else
         Result := Device_Not_Found;
      end if;
   end Enumerate_Cpus;
end Kernel.Device_Tree;
