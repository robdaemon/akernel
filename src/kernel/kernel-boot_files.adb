with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;
with Kernel.Initrd;

package body Kernel.Boot_Files is
   use type Interfaces.Unsigned_64;
   use type Kernel.Initrd.Status;

   subtype U8 is Interfaces.Unsigned_8;
   type U8_Access is access all U8;

   function To_U8_Access is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => U8_Access);

   function Path (File_Id : U64) return String is
   begin
      case File_Id is
         when Manifest_File =>
            return "System/Manifest";
         when others =>
            return "";
      end case;
   end Path;

   procedure Locate
     (File_Id : U64;
      Result  : out Status;
      Base    : out U64;
      Length  : out U64)
   is
      Init_Result : Kernel.Initrd.Status;
      Name        : constant String := Path (File_Id);
   begin
      Base := 0;
      Length := 0;

      if Name'Length = 0 then
         Result := Invalid_File;
         return;
      end if;

      Kernel.Initrd.Find
        (Name   => Name,
         Result => Init_Result,
         Base   => Base,
         Size   => Length);

      case Init_Result is
         when Kernel.Initrd.Ok =>
            Result := Ok;
         when Kernel.Initrd.Not_Found =>
            Result := Not_Found;
         when others =>
            Result := Bad_Image;
      end case;
   end Locate;

   procedure Size
     (File_Id : U64;
      Result  : out Status;
      Length  : out U64)
   is
      Base : U64;
   begin
      Locate (File_Id, Result, Base, Length);
   end Size;

   procedure Read_Byte
     (File_Id : U64;
      Offset  : U64;
      Result  : out Status;
      Value   : out U64)
   is
      Base   : U64;
      Length : U64;
      Addr   : System.Address;
      Ptr    : U8_Access;
   begin
      Value := 0;
      Locate (File_Id, Result, Base, Length);
      if Result /= Ok then
         return;
      end if;

      if Offset >= Length then
         Result := Out_Of_Range;
         return;
      end if;

      Addr := System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (Base + Offset));
      Ptr := To_U8_Access (Addr);
      Value := U64 (Ptr.all);
      Result := Ok;
   end Read_Byte;
end Kernel.Boot_Files;
