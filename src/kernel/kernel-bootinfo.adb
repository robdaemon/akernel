with System;
with System.Storage_Elements;
with Arch;
with Arch.MMU;
with Kernel.Physical_Memory;

package body Kernel.Bootinfo is
   use type Interfaces.Unsigned_64;
   use type Arch.MMU.Status;
   use type Kernel.Physical_Memory.Status;
   use System.Storage_Elements;

   subtype U8 is Interfaces.Unsigned_8;

   type Word_Array is array (U64 range <>) of U64;
   type Byte_Array is array (U64 range <>) of U8;

   Frame_PA   : U64 := 0;
   Entry_Count : U64 := 0;

   Header_Offset  : constant U64 := 0;   --  +0 magic, +8 entry count
   Entries_Offset : constant U64 := 16;

   function Page_Address return System.Address is
     (System'To_Address (Integer_Address (Arch.Phys_To_Virt (Frame_PA))));

   procedure Write_Word (Offset : U64; Value : U64) is
      Words : Word_Array (0 .. 511) with Address => Page_Address;
   begin
      Words (Offset / 8) := Value;
   end Write_Word;

   procedure Write_Name (Offset : U64; Name : String) is
      Bytes : Byte_Array (0 .. 4095) with Address => Page_Address;
   begin
      for Index in Name'Range loop
         Bytes (Offset + U64 (Index - Name'First)) :=
           U8 (Character'Pos (Name (Index)));
      end loop;
   end Write_Name;

   procedure Install
     (Root   : U64;
      Result : out Status)
   is
      PMM_Result : Kernel.Physical_Memory.Status;
      MMU_Result : Arch.MMU.Status;
   begin
      Result := Ok;

      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame_PA);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Frame_PA := 0;
         Result := Allocation_Failed;
         return;
      end if;

      Arch.MMU.Map_Page
        (Root     => Root,
         Virtual  => VA,
         Physical => Frame_PA,
         Flags    => Arch.MMU.User_RO,
         Result   => MMU_Result);

      if MMU_Result /= Arch.MMU.Ok then
         Kernel.Physical_Memory.Deallocate_Frame (Frame_PA, PMM_Result);
         Frame_PA := 0;
         Result := Map_Failed;
         return;
      end if;

      --  Zero via the physmap. The overlay address must be computed
      --  only now that Frame_PA holds the allocated frame.
      declare
         Words : Word_Array (0 .. 511) with Address => Page_Address;
      begin
         Words := (others => 0);
      end;

      Entry_Count := 0;
      Write_Word (Header_Offset, Magic);
   end Install;

   procedure Add
     (Handle      : U64;
      Kind        : U64;
      Rights_Mask : U64;
      Name        : String;
      Result      : out Status)
   is
      Base : U64;
   begin
      Result := Ok;

      if Frame_PA = 0 then
         Result := Not_Installed;
         return;
      end if;

      if Entry_Count >= U64 (Max_Entries)
        or else Name'Length > Max_Name
      then
         Result := Full;
         return;
      end if;

      Base := Entries_Offset + Entry_Count * Entry_Size;
      Write_Word (Base, Handle);
      Write_Word (Base + 8, Kind);
      Write_Word (Base + 16, Rights_Mask);
      Write_Word (Base + 24, U64 (Name'Length));
      Write_Name (Base + 32, Name);

      Entry_Count := Entry_Count + 1;
      Write_Word (8, Entry_Count);
   end Add;
end Kernel.Bootinfo;
