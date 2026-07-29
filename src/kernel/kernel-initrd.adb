package body Kernel.Initrd is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U32 is Interfaces.Unsigned_32;

   Header_Size : constant U64 := 24;
   CPIO_Header_Size : constant U64 := 110;

   function Mmio_Read8 (Address : U64) return U8
     with Import, Convention => C, External_Name => "mmio_read8";

   function Read_LE32 (Address : U64) return U32 is
      B0 : constant U32 := U32 (Mmio_Read8 (Address));
      B1 : constant U32 := U32 (Mmio_Read8 (Address + 1));
      B2 : constant U32 := U32 (Mmio_Read8 (Address + 2));
      B3 : constant U32 := U32 (Mmio_Read8 (Address + 3));
   begin
      return B0
        or Interfaces.Shift_Left (B1, 8)
        or Interfaces.Shift_Left (B2, 16)
        or Interfaces.Shift_Left (B3, 24);
   end Read_LE32;

   function Read_LE64 (Address : U64) return U64 is
      Lo : constant U64 := U64 (Read_LE32 (Address));
      Hi : constant U64 := U64 (Read_LE32 (Address + 4));
   begin
      return Lo or Interfaces.Shift_Left (Hi, 32);
   end Read_LE64;

   function Align_4 (Value : U64) return U64 is
   begin
      return Value + ((4 - Value mod 4) mod 4);
   end Align_4;

   function Hex_Value (C : U8) return U32 is
   begin
      if C >= Character'Pos ('0') and then C <= Character'Pos ('9') then
         return U32 (C - Character'Pos ('0'));
      elsif C >= Character'Pos ('a') and then C <= Character'Pos ('f') then
         return U32 (C - Character'Pos ('a') + 10);
      elsif C >= Character'Pos ('A') and then C <= Character'Pos ('F') then
         return U32 (C - Character'Pos ('A') + 10);
      else
         return 0;
      end if;
   end Hex_Value;

   function Read_Hex8 (Address : U64) return U32 is
      Value : U32 := 0;
   begin
      for Index in U64 range 0 .. 7 loop
         Value := Interfaces.Shift_Left (Value, 4)
           or Hex_Value (Mmio_Read8 (Address + Index));
      end loop;
      return Value;
   end Read_Hex8;

   function Bytes_Equal (Address : U64; Text : String) return Boolean is
      Offset : U64 := 0;
   begin
      for C of Text loop
         if Mmio_Read8 (Address + Offset) /= Character'Pos (C) then
            return False;
         end if;
         Offset := Offset + 1;
      end loop;
      return True;
   end Bytes_Equal;

   function CPIO_Name_Equals
     (Address : U64;
      Size    : U64;
      Name    : String) return Boolean
   is
      Offset : U64 := 0;
   begin
      if Size /= Name'Length + 1 then
         return False;
      end if;

      for C of Name loop
         if Mmio_Read8 (Address + Offset) /= Character'Pos (C) then
            return False;
         end if;
         Offset := Offset + 1;
      end loop;

      return Mmio_Read8 (Address + Offset) = 0;
   end CPIO_Name_Equals;

   procedure Find
     (Name   : String;
      Result : out Status;
      Base   : out U64;
      Size   : out U64)
   is
      CPIO_Size : U64;
      Cursor    : U64;
      End_Addr  : U64;
      File_Size : U64;
      Name_Size : U64;
      Name_Addr : U64;
      Data_Addr : U64;
   begin
      Base := 0;
      Size := 0;

      if not Bytes_Equal (Initrd_Base, "AKRD")
        or else Read_LE32 (Initrd_Base + 4) /= 1
      then
         Result := Bad_Header;
         return;
      end if;

      CPIO_Size := Read_LE64 (Initrd_Base + 8);
      Cursor := Initrd_Base + Header_Size;
      End_Addr := Cursor + CPIO_Size;

      while Cursor + CPIO_Header_Size <= End_Addr loop
         if not Bytes_Equal (Cursor, "070701") then
            Result := Bad_CPIO;
            return;
         end if;

         File_Size := U64 (Read_Hex8 (Cursor + 54));
         Name_Size := U64 (Read_Hex8 (Cursor + 94));
         Name_Addr := Cursor + CPIO_Header_Size;
         Data_Addr := Align_4 (Name_Addr + Name_Size);

         if CPIO_Name_Equals (Name_Addr, Name_Size, "TRAILER!!!") then
            exit;
         end if;

         if CPIO_Name_Equals (Name_Addr, Name_Size, Name) then
            Base := Data_Addr;
            Size := File_Size;
            Result := Ok;
            return;
         end if;

         Cursor := Align_4 (Data_Addr + File_Size);
      end loop;

      Result := Not_Found;
   end Find;

   Iteration_Cursor : U64 := 0;
   Iteration_Active : Boolean := False;

   procedure Reset_Iteration is
   begin
      Iteration_Cursor := 0;
      Iteration_Active := False;
   end Reset_Iteration;

   procedure Next
     (Result      : out Status;
      Name        : out String;
      Name_Length : out Natural;
      Base        : out U64;
      Size        : out U64)
   is
      CPIO_Size : U64;
      End_Addr  : U64;
      File_Size : U64;
      Name_Size : U64;
      Name_Addr : U64;
      Data_Addr : U64;
   begin
      Base := 0;
      Size := 0;
      Name_Length := 0;

      if not Iteration_Active then
         if not Bytes_Equal (Initrd_Base, "AKRD")
           or else Read_LE32 (Initrd_Base + 4) /= 1
         then
            Result := Bad_Header;
            return;
         end if;

         Iteration_Cursor := Initrd_Base + Header_Size;
         Iteration_Active := True;
      end if;

      CPIO_Size := Read_LE64 (Initrd_Base + 8);
      End_Addr := Initrd_Base + Header_Size + CPIO_Size;

      if Iteration_Cursor + CPIO_Header_Size > End_Addr then
         Iteration_Active := False;
         Result := Not_Found;
         return;
      end if;

      if not Bytes_Equal (Iteration_Cursor, "070701") then
         Iteration_Active := False;
         Result := Bad_CPIO;
         return;
      end if;

      File_Size := U64 (Read_Hex8 (Iteration_Cursor + 54));
      Name_Size := U64 (Read_Hex8 (Iteration_Cursor + 94));
      Name_Addr := Iteration_Cursor + CPIO_Header_Size;
      Data_Addr := Align_4 (Name_Addr + Name_Size);
      Iteration_Cursor := Align_4 (Data_Addr + File_Size);

      if CPIO_Name_Equals (Name_Addr, Name_Size, "TRAILER!!!") then
         Iteration_Active := False;
         Result := Not_Found;
         return;
      end if;

      if Name_Size > 0 then
         Name_Length := Natural'Min (Natural (Name_Size) - 1, Name'Length);
         for Index in 1 .. Name_Length loop
            Name (Index) := Character'Val
              (Natural (Mmio_Read8 (Name_Addr + U64 (Index - 1))));
         end loop;
      end if;

      Base := Data_Addr;
      Size := File_Size;
      Result := Ok;
   end Next;
end Kernel.Initrd;
