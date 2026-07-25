with Arch.MMU;
with Kernel.Physical_Memory;

package body Kernel.ELF is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U8  is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;

   PT_LOAD : constant U32 := 1;
   EM_RISCV : constant U16 := 243;

   PF_X : constant U32 := 1;
   PF_W : constant U32 := 2;
   PF_R : constant U32 := 4;

   function Mmio_Read8 (Address : U64) return U8
     with Import, Convention => C, External_Name => "mmio_read8";

   procedure Mmio_Write8 (Address : U64; Value : U8)
     with Import, Convention => C, External_Name => "mmio_write8";

   function Read_LE16 (Address : U64) return U16 is
      B0 : constant U16 := U16 (Mmio_Read8 (Address));
      B1 : constant U16 := U16 (Mmio_Read8 (Address + 1));
   begin
      return B0 or Interfaces.Shift_Left (B1, 8);
   end Read_LE16;

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

   procedure Copy_Bytes
     (Destination : U64;
      Source      : U64;
      Count       : U64)
   is
   begin
      if Count = 0 then
         return;
      end if;

      for Offset in U64 range 0 .. Count - 1 loop
         Mmio_Write8 (Destination + Offset, Mmio_Read8 (Source + Offset));
      end loop;
   end Copy_Bytes;

   procedure Zero_Bytes
     (Destination : U64;
      Count       : U64)
   is
   begin
      if Count = 0 then
         return;
      end if;

      for Offset in U64 range 0 .. Count - 1 loop
         Mmio_Write8 (Destination + Offset, 0);
      end loop;
   end Zero_Bytes;

   function Max (Left : U64; Right : U64) return U64 is
   begin
      if Left > Right then
         return Left;
      else
         return Right;
      end if;
   end Max;

   function Min (Left : U64; Right : U64) return U64 is
   begin
      if Left < Right then
         return Left;
      else
         return Right;
      end if;
   end Min;

   function Align_Down (Value : U64; Alignment : U64) return U64 is
   begin
      return Value - Value mod Alignment;
   end Align_Down;

   function Align_Up (Value : U64; Alignment : U64) return U64 is
   begin
      return ((Value + Alignment - 1) / Alignment) * Alignment;
   end Align_Up;

   function Page_Flags (P_Flags : U32) return Arch.MMU.Page_Flags is
   begin
      return
        (Read    => (P_Flags and PF_R) /= 0,
         Write   => (P_Flags and PF_W) /= 0,
         Execute => (P_Flags and PF_X) /= 0,
         User    => True,
         Global  => False);
   end Page_Flags;

   procedure Load_User_Alias
     (Image_Base : U64;
      Image_Size : U64;
      Result      : out Status;
      Entry_Point : out U64)
   is
      PH_Offset : U64;
      PH_Entry_Size : U16;
      PH_Count : U16;
      PH       : U64;
      P_Type   : U32;
      P_Offset : U64;
      P_VAddr  : U64;
      P_Filesz : U64;
      P_Memsz  : U64;
      Dest     : U64;
   begin
      Entry_Point := 0;

      if Image_Size < 64
        or else Mmio_Read8 (Image_Base) /= 16#7f#
        or else Mmio_Read8 (Image_Base + 1) /= Character'Pos ('E')
        or else Mmio_Read8 (Image_Base + 2) /= Character'Pos ('L')
        or else Mmio_Read8 (Image_Base + 3) /= Character'Pos ('F')
      then
         Result := Bad_Magic;
         return;
      end if;

      if Mmio_Read8 (Image_Base + 4) /= 2      -- ELFCLASS64
        or else Mmio_Read8 (Image_Base + 5) /= 1 -- little endian
        or else Read_LE16 (Image_Base + 18) /= EM_RISCV
      then
         Result := Unsupported;
         return;
      end if;

      Entry_Point := Read_LE64 (Image_Base + 24);
      PH_Offset := Read_LE64 (Image_Base + 32);
      PH_Entry_Size := Read_LE16 (Image_Base + 54);
      PH_Count := Read_LE16 (Image_Base + 56);

      if PH_Entry_Size < 56 then
         Result := Unsupported;
         return;
      end if;

      for Index in U16 range 0 .. PH_Count - 1 loop
         PH := Image_Base + PH_Offset + U64 (Index) * U64 (PH_Entry_Size);
         if PH + 56 > Image_Base + Image_Size then
            Result := Bad_Image;
            return;
         end if;

         P_Type := Read_LE32 (PH);
         if P_Type = PT_LOAD then
            P_Offset := Read_LE64 (PH + 8);
            P_VAddr := Read_LE64 (PH + 16);
            P_Filesz := Read_LE64 (PH + 32);
            P_Memsz := Read_LE64 (PH + 40);

            if P_Offset + P_Filesz > Image_Size or else P_Filesz > P_Memsz then
               Result := Bad_Image;
               return;
            end if;

            Dest := P_VAddr + User_Alias_Delta;
            Copy_Bytes (Dest, Image_Base + P_Offset, P_Filesz);
            Zero_Bytes (Dest + P_Filesz, P_Memsz - P_Filesz);
         end if;
      end loop;

      Result := Ok;
   end Load_User_Alias;

   procedure Load_Into_Address_Space
     (Image_Base  : U64;
      Image_Size  : U64;
      Root        : U64;
      Result      : out Status;
      Entry_Point : out U64)
   is
      use type Arch.MMU.Status;
      use type Kernel.Physical_Memory.Status;

      PH_Offset     : U64;
      PH_Entry_Size : U16;
      PH_Count      : U16;
      PH            : U64;
      P_Type        : U32;
      P_Flags       : U32;
      P_Offset      : U64;
      P_VAddr       : U64;
      P_Filesz      : U64;
      P_Memsz       : U64;
      Segment_Start : U64;
      Segment_End   : U64;
      Page_VA       : U64;
      Frame         : U64;
      Copy_Start    : U64;
      Copy_End      : U64;
      Copy_Count    : U64;
      Alloc_Result  : Kernel.Physical_Memory.Status;
      Map_Result    : Arch.MMU.Status;
   begin
      Entry_Point := 0;

      if Image_Size < 64
        or else Mmio_Read8 (Image_Base) /= 16#7f#
        or else Mmio_Read8 (Image_Base + 1) /= Character'Pos ('E')
        or else Mmio_Read8 (Image_Base + 2) /= Character'Pos ('L')
        or else Mmio_Read8 (Image_Base + 3) /= Character'Pos ('F')
      then
         Result := Bad_Magic;
         return;
      end if;

      if Mmio_Read8 (Image_Base + 4) /= 2
        or else Mmio_Read8 (Image_Base + 5) /= 1
        or else Read_LE16 (Image_Base + 18) /= EM_RISCV
      then
         Result := Unsupported;
         return;
      end if;

      Entry_Point := Read_LE64 (Image_Base + 24);
      PH_Offset := Read_LE64 (Image_Base + 32);
      PH_Entry_Size := Read_LE16 (Image_Base + 54);
      PH_Count := Read_LE16 (Image_Base + 56);

      if PH_Entry_Size < 56 then
         Result := Unsupported;
         return;
      end if;

      for Index in U16 range 0 .. PH_Count - 1 loop
         PH := Image_Base + PH_Offset + U64 (Index) * U64 (PH_Entry_Size);
         if PH + 56 > Image_Base + Image_Size then
            Result := Bad_Image;
            return;
         end if;

         P_Type := Read_LE32 (PH);
         if P_Type = PT_LOAD then
            P_Flags := Read_LE32 (PH + 4);
            P_Offset := Read_LE64 (PH + 8);
            P_VAddr := Read_LE64 (PH + 16);
            P_Filesz := Read_LE64 (PH + 32);
            P_Memsz := Read_LE64 (PH + 40);

            if P_Offset + P_Filesz > Image_Size or else P_Filesz > P_Memsz then
               Result := Bad_Image;
               return;
            end if;

            Segment_Start := Align_Down (P_VAddr, Arch.MMU.Page_Size);
            Segment_End := Align_Up (P_VAddr + P_Memsz, Arch.MMU.Page_Size);
            Page_VA := Segment_Start;

            while Page_VA < Segment_End loop
               Kernel.Physical_Memory.Allocate_Frame (Alloc_Result, Frame);
               if Alloc_Result /= Kernel.Physical_Memory.Ok then
                  Result := Bad_Image;
                  return;
               end if;

               Zero_Bytes (Frame, Arch.MMU.Page_Size);
               Copy_Start := Max (Page_VA, P_VAddr);
               Copy_End :=
                 Min (Page_VA + Arch.MMU.Page_Size, P_VAddr + P_Filesz);

               if Copy_End > Copy_Start then
                  Copy_Count := Copy_End - Copy_Start;
                  Copy_Bytes
                    (Destination => Frame + (Copy_Start - Page_VA),
                     Source      =>
                       Image_Base + P_Offset + (Copy_Start - P_VAddr),
                     Count       => Copy_Count);
               end if;

               Arch.MMU.Map_Page
                 (Root     => Root,
                  Virtual  => Page_VA,
                  Physical => Frame,
                  Flags    => Page_Flags (P_Flags),
                  Result   => Map_Result);

               if Map_Result /= Arch.MMU.Ok then
                  Result := Bad_Image;
                  return;
               end if;

               Page_VA := Page_VA + Arch.MMU.Page_Size;
            end loop;
         end if;
      end loop;

      Result := Ok;
   end Load_Into_Address_Space;
end Kernel.ELF;
