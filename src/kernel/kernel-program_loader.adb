with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;
with Kernel.Initrd;

package body Kernel.Program_Loader is
   use type Interfaces.Unsigned_64;
   use type Kernel.Initrd.Status;

   subtype U8 is Interfaces.Unsigned_8;

   type U8_Access is access all U8;
   function To_U8_Access is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => U8_Access);

   Max_Token_Length : constant := 64;
   subtype Token_String is String (1 .. Max_Token_Length);

   Manifest_Path : constant String := "System/Manifest";

   function Byte_At (Base : U64; Offset : U64) return U8 is
      Addr : constant System.Address := System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (Base + Offset));
      Ptr  : constant U8_Access := To_U8_Access (Addr);
   begin
      return Ptr.all;
   end Byte_At;

   procedure Find_By_Manifest_Path
     (Path_Offset : U64;
      Path_Length : U64;
      Result      : out Status;
      Image       : out Program_Image)
   is
      Init_Result   : Kernel.Initrd.Status;
      Manifest_Base : U64;
      Manifest_Size : U64;
      Path          : Token_String;
   begin
      Image := (Base => 0, Size => 0);

      if Path_Length = 0 or else Path_Length > Max_Token_Length then
         Result := Invalid_Program;
         return;
      end if;

      Kernel.Initrd.Find
        (Name   => Manifest_Path,
         Result => Init_Result,
         Base   => Manifest_Base,
         Size   => Manifest_Size);

      if Init_Result = Kernel.Initrd.Not_Found then
         Result := Not_Found;
         return;
      elsif Init_Result /= Kernel.Initrd.Ok then
         Result := Bad_Image;
         return;
      end if;

      if Path_Offset > Manifest_Size then
         Result := Invalid_Program;
         return;
      end if;

      if Path_Offset + Path_Length > Manifest_Size then
         Result := Invalid_Program;
         return;
      end if;

      Path := (others => Character'Val (0));
      for Index in U64 range 0 .. Path_Length - 1 loop
         Path (Natural (Index) + 1) := Character'Val
           (Natural (Byte_At (Manifest_Base, Path_Offset + Index)));
      end loop;

      Kernel.Initrd.Find
        (Name   => Path (1 .. Natural (Path_Length)),
         Result => Init_Result,
         Base   => Image.Base,
         Size   => Image.Size);

      case Init_Result is
         when Kernel.Initrd.Ok =>
            Result := Ok;
         when Kernel.Initrd.Not_Found =>
            Result := Not_Found;
         when others =>
            Result := Bad_Image;
      end case;
   end Find_By_Manifest_Path;
end Kernel.Program_Loader;
